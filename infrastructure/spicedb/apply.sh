#!/usr/bin/env bash
# Idempotent installer for SpiceDB (Phase 4.3).
#
# Order matters:
#   1. Apply Operator bundle → CRDs + spicedb-operator ns + Operator Deploy.
#   2. Wait for Operator Ready.
#   3. Build the `spicedb-config` Secret (random PSK + Postgres DSN).
#   4. Apply ServiceAccount, cert-manager Certificate, NetworkPolicies.
#   5. Apply SpiceDBCluster CR.
#   6. Wait for the SpiceDB Deployment to be Ready.
#
# Re-running:
#   - the PSK Secret is preserved (regeneration would invalidate clients)
#   - other resources are upserted
# To rotate the PSK, see docs/03-runbooks/spicedb-operations.md.

set -euo pipefail

NS=spicedb
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}

require_cmd kubectl
require_cmd openssl
require_cmd jq

# 1. Operator bundle.
green "==> Applying SpiceDB Operator bundle"
kubectl apply --server-side -f "$HERE/operator/bundle.yaml"

green "==> Waiting for spicedb-operator Deployment Ready"
kubectl -n spicedb-operator rollout status deployment/spicedb-operator --timeout=180s

# 2. Build the spicedb-config Secret.
if ! kubectl -n "$NS" get secret spicedb-config >/dev/null 2>&1; then
    green "==> Generating PSK and assembling datastore_uri"

    PG_USER=$(kubectl get secret -n "$NS" secforge-spicedb-db-app -o jsonpath='{.data.username}' | base64 -d)
    PG_PASS=$(kubectl get secret -n "$NS" secforge-spicedb-db-app -o jsonpath='{.data.password}' | base64 -d)
    PG_HOST="secforge-spicedb-db-rw.${NS}.svc"
    PG_DB=$(kubectl get secret -n "$NS" secforge-spicedb-db-app -o jsonpath='{.data.dbname}' | base64 -d)

    DATASTORE_URI="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:5432/${PG_DB}?sslmode=require"
    PSK="$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)"

    kubectl create secret generic spicedb-config \
        --namespace "$NS" \
        --from-literal=preshared_key="${PSK}" \
        --from-literal=datastore_uri="${DATASTORE_URI}"
    kubectl -n "$NS" label secret spicedb-config \
        app.kubernetes.io/name=spicedb \
        secforge.platform/component=spicedb \
        --overwrite

    yellow ""
    yellow "==================================================================="
    yellow "SPICEDB PRESHARED KEY (used by zed CLI / AuthZEN façade — save once):"
    yellow "  $PSK"
    yellow ""
    yellow "Phase 5 replaces this static PSK with an OpenBao-issued, SPIFFE-"
    yellow "bound, short-lived credential. Until then, the Secret"
    yellow "  spicedb/spicedb-config (key: preshared_key)"
    yellow "is the source of truth — fetch from there in scripts."
    yellow "==================================================================="
    yellow ""
    unset PG_PASS PSK DATASTORE_URI
else
    green "==> spicedb-config Secret exists; reusing"
fi

# 3. Apply SA, cert, NetworkPolicies.
green "==> Applying ServiceAccount"
kubectl apply -f "$HERE/01-serviceaccount.yaml"

green "==> Applying TLS Certificate"
kubectl apply -f "$HERE/03-certificate.yaml"

green "==> Applying NetworkPolicies"
kubectl apply -f "$HERE/05-networkpolicies.yaml"

# 4. Apply the SpiceDBCluster CR.
green "==> Applying SpiceDBCluster CR"
kubectl apply -f "$HERE/04-spicedb-cr.yaml"

# 5. Wait for the operator-managed Deployment to come up.
green "==> Waiting for SpiceDB Deployment to be created (operator may take ~30s)"
for i in {1..30}; do
    if kubectl -n "$NS" get deployment spicedb >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

green "==> Waiting for SpiceDB pods Ready"
kubectl -n "$NS" rollout status deployment/spicedb --timeout=300s

green ""
green "SpiceDB is up. Next:"
green "  - Apply the schema:  bash infrastructure/spicedb/apply-schema.sh"
green "  - Run verify:        bash infrastructure/spicedb/verify.sh"
green ""
