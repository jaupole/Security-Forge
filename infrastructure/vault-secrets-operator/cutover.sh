#!/usr/bin/env bash
# Phase 6.10b Step 3 cutover — orchestrate the SpiceDB + AuthZEN move
# from manually-created K8s Secrets to VSO-rendered Secrets.
#
# Idempotent. Each step checks state before acting.
#
# Pre-conditions (Step 2 + Step 3 prep):
#   - VSO installed and healthy (Step 2 verify.sh passed)
#   - OpenBao role updated for THREE consumers
#     (configure-openbao-role.sh re-run after Step 3 manifest changes)
#   - secret/data/spicedb/config populated in OpenBao
#     (migrate-datastore-uri-to-openbao.sh has been run)
#
# Order:
#   1. Populate `spicedb-ca-bundle` ConfigMap in app ns (CA from mkcert).
#   2. Apply spicedb-side binding (SA + VaultAuth + VaultStaticSecret).
#   3. Apply app-side binding (SA + VaultAuth + VaultStaticSecret).
#   4. Wait for both VSO-rendered Secrets to exist + be healthy.
#   5. Apply updated SpiceDBCluster CR (secretName flip).
#      Operator rolls SpiceDB; wait for the new pod Ready.
#   6. Roll AuthZEN Deployment to pick up the new projected volume.
#   7. Run check-permissions.sh against SpiceDB (sanity).
#   8. Print soak instructions; this script does NOT block for 10 min.
#      The actual ≥10-min soak is the user's call before running Step 4.
#
# What this script does NOT do (deliberately):
#   - Step 4 (delete the original Secrets) — destructive, manual.
#   - Step 5 (BFF cleanup) — separate, lower-risk.
#   - Step 6 (ADR-0015 finalization, PLAN.md updates) — manual review.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}
require_cmd kubectl

# Sanity: VSO must be healthy before we add new VaultStaticSecrets.
green "==> sanity: VSO controller is Ready"
if ! kubectl -n vault-secrets-operator rollout status \
        deployment/vault-secrets-operator-controller-manager --timeout=30s; then
    red "VSO is not Ready. Re-run apply.sh + verify.sh from Step 2 first."
    exit 1
fi

# Sanity: secret/data/spicedb/config is populated. We probe via VSO's
# operator-self auth (which can read it; the policy includes the path).
# Skip: this is hard to verify without running bao directly. Instead we
# trust that the migration script was run and let VSO surface a read
# error in step 4's healthy-status check.

# 1. CA bundle ConfigMap in app ns.
#    Sourced from cert-manager/mkcert-ca-key-pair (.data.tls.crt) and
#    rewritten with key `ca.crt` to match AuthZEN's existing mountPath.
green "==> writing app/spicedb-ca-bundle ConfigMap (mkcert CA → key ca.crt)"
CA_PEM=$(kubectl get secret -n cert-manager mkcert-ca-key-pair \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [ -z "$CA_PEM" ]; then
    red "could not read mkcert-ca-key-pair from cert-manager namespace"
    exit 1
fi
kubectl create configmap spicedb-ca-bundle \
    -n app \
    --from-literal=ca.crt="$CA_PEM" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n app label configmap spicedb-ca-bundle \
    secforge.platform/component=authzen-facade \
    secforge.platform/role=ca-bundle \
    --overwrite >/dev/null

# 2. spicedb-side binding.
green "==> applying spicedb VSO binding (SA + VaultAuth + VaultStaticSecret)"
kubectl apply -f "$REPO_ROOT/infrastructure/spicedb/06-vso-binding.yaml"

# 3. app-side binding.
green "==> applying authzen-facade VSO binding (SA + VaultAuth + VaultStaticSecret)"
kubectl apply -f "$REPO_ROOT/apps/authzen-facade/deploy/05-vso-binding.yaml"

# 4. Wait for both VaultStaticSecrets healthy + their rendered Secrets to exist.
wait_for_secret() {
    local ns="$1" name="$2" timeout="${3:-60}"
    green "==> waiting up to ${timeout}s for $ns/$name to exist"
    for _ in $(seq 1 "$timeout"); do
        if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
            green "    ok"
            return 0
        fi
        sleep 1
    done
    red "$ns/$name was not rendered within ${timeout}s"
    red "Check VSO logs:"
    red "  kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=80"
    return 1
}

wait_for_secret spicedb spicedb-config-vso 60
wait_for_secret app authzen-facade-spicedb-creds-vso 60

# Sanity-check: rendered Secrets contain the expected keys.
green "==> verifying spicedb/spicedb-config-vso has preshared_key + datastore_uri"
SPICEDB_KEYS=$(kubectl get secret -n spicedb spicedb-config-vso \
    -o jsonpath='{.data}' | tr -cd 'a-z_,' | tr ',' '\n' | sort | uniq)
if ! echo "$SPICEDB_KEYS" | grep -q "preshared_key" || \
   ! echo "$SPICEDB_KEYS" | grep -q "datastore_uri"; then
    red "spicedb-config-vso is missing required keys. Got: $SPICEDB_KEYS"
    red "Check OpenBao path secret/data/spicedb/config — did the migration run?"
    exit 1
fi
green "    ok"

green "==> verifying app/authzen-facade-spicedb-creds-vso has preshared_key"
AUTHZEN_KEYS=$(kubectl get secret -n app authzen-facade-spicedb-creds-vso \
    -o jsonpath='{.data}' | tr -cd 'a-z_,' | tr ',' '\n' | sort | uniq)
if ! echo "$AUTHZEN_KEYS" | grep -q "preshared_key"; then
    red "authzen-facade-spicedb-creds-vso is missing preshared_key. Got: $AUTHZEN_KEYS"
    exit 1
fi
green "    ok"

# 5. Roll SpiceDB onto the new Secret.
green "==> applying updated SpiceDBCluster (secretName: spicedb-config-vso)"
kubectl apply -f "$REPO_ROOT/infrastructure/spicedb/04-spicedb-cr.yaml"

green "==> waiting for SpiceDB Operator to reconcile + Deployment to roll"
sleep 5  # give the operator a moment to observe the CR change
# Operator names the Deployment <cluster>-spicedb (e.g. spicedb-spicedb).
kubectl -n spicedb rollout status deployment/spicedb-spicedb --timeout=180s

# 6. Roll AuthZEN to pick up the new projected volume.
green "==> applying updated AuthZEN Deployment (projected volume from VSO Secret + CM)"
kubectl apply -f "$REPO_ROOT/apps/authzen-facade/deploy/02-deployment.yaml"

green "==> waiting for AuthZEN rollout"
kubectl -n app rollout status deployment/authzen-facade --timeout=180s

# 7. Run the existing CheckPermission sanity to confirm SpiceDB is alive
#    on the new PSK + datastore.
green "==> running CheckPermission sanity (infrastructure/spicedb/check-permissions.sh)"
if [ -x "$REPO_ROOT/infrastructure/spicedb/check-permissions.sh" ]; then
    bash "$REPO_ROOT/infrastructure/spicedb/check-permissions.sh" || {
        red "check-permissions.sh failed. Investigate before proceeding."
        red "Rollback: kubectl edit spicedbcluster spicedb -n spicedb"
        red "          (set secretName: spicedb-config), and re-roll."
        exit 1
    }
else
    yellow "check-permissions.sh not executable; skipping. Run manually."
fi

# 8. Soak instructions.
green ""
green "============================================================"
green "Step 3 cutover applied. NEXT: ≥10-minute soak."
green "============================================================"
green ""
green "Watch SpiceDB + AuthZEN for restart loops, log errors, or VSO"
green "refresh-cycle weirdness. Suggested commands:"
green ""
green "  kubectl -n spicedb get pods -w               # restarts?"
green "  kubectl -n app get pods -w                   # AuthZEN ok?"
green "  kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f"
green "  bash infrastructure/spicedb/check-permissions.sh"
green ""
green "After ≥10 minutes of green-line soak, you can proceed to Step 4:"
green "  kubectl delete secret spicedb-config -n spicedb"
green "  kubectl delete secret authzen-facade-spicedb-creds -n app"
green ""
green "If anything fails during soak, rollback via:"
green "  - SpiceDB: edit spicedbcluster.spicedb spicedb, set"
green "    secretName: spicedb-config, kubectl rollout restart"
green "  - AuthZEN: revert apps/authzen-facade/deploy/02-deployment.yaml"
green "    to the original spicedb-creds Secret volume, kubectl apply"
green "  Investigate the failure mode before retrying the cutover."
green ""
