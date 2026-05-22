#!/usr/bin/env bash
# 05j — Migrate SpiceDB from the legacy `spicedb-config` Secret to the
# VSO-rendered `spicedb-config-vso` Secret backed by OpenBao at
# `secret/data/spicedb/config`.
#
# Steps:
#   1. Read existing PSK + datastore_uri from K8s Secret spicedb/spicedb-config
#   2. Stash both into OpenBao at secret/spicedb/config
#   3. Apply the VSO binding (SA + VaultAuth + VaultStaticSecret) in spicedb ns
#   4. Create OpenBao K8s auth role spicedb-vso bound to the spicedb-vso SA + vso policy
#   5. Wait for the rendered K8s Secret spicedb/spicedb-config-vso to appear
#   6. Update the SpiceDBCluster CR's secretName: spicedb-config -> spicedb-config-vso
#   7. Wait for the SpiceDB Operator to roll the Deployment
#   8. Verify SpiceDB pod is Ready
#
# Pre-conditions:
#   - 05c-i (OpenBao Layer 1+2) all complete
#   - openbao-root-token-tmp Secret in openbao ns (paste from 1Password)
#   - VSO operational (05d/05e)
#
# Idempotent.

set -euo pipefail

NS_BAO=openbao
NS_SPICEDB=spicedb
POD_BAO=openbao-0

# Pre-flight: secrets
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  echo "ERROR: openbao-root-token-tmp Secret not found." >&2
  echo "       Re-create with the OpenBao initial root token from 1Password." >&2
  exit 1
fi
if ! kubectl -n "$NS_SPICEDB" get secret spicedb-config >/dev/null 2>&1; then
  echo "ERROR: legacy spicedb-config Secret not found in $NS_SPICEDB. Nothing to migrate." >&2
  exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1+2. Stash existing values into OpenBao.
echo ">>> Reading current spicedb-config Secret values"
PSK=$(kubectl -n "$NS_SPICEDB" get secret spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)
DSN=$(kubectl -n "$NS_SPICEDB" get secret spicedb-config -o jsonpath='{.data.datastore_uri}' | base64 -d)

if [[ -z "$PSK" || -z "$DSN" ]]; then
  echo "ERROR: spicedb-config missing preshared_key or datastore_uri" >&2
  unset ROOT_TOKEN PSK DSN
  exit 1
fi

echo ">>> Stashing PSK + datastore_uri into OpenBao at secret/spicedb/config"
bao bao kv put secret/spicedb/config preshared_key="$PSK" datastore_uri="$DSN" 2>&1 | tail -3 >/dev/null
unset PSK DSN

# Verify the stash worked (read back metadata only — no values)
if ! bao bao kv get -format=json secret/spicedb/config >/dev/null 2>&1; then
  echo "ERROR: failed to read back secret/spicedb/config from OpenBao" >&2
  unset ROOT_TOKEN
  exit 1
fi
echo "    stash verified"

# 3. Apply the VSO binding (SA + VaultAuth + VaultStaticSecret).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
echo ">>> Applying VSO binding in spicedb namespace"
kubectl apply -f "$PLATFORM_DIR/manifests/spicedb-vso/binding.yaml"

# 4. Create OpenBao K8s auth role for spicedb-vso SA.
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
echo ">>> Writing OpenBao K8s auth role: spicedb-vso"
bao bao write auth/kubernetes/role/spicedb-vso \
  bound_service_account_names="spicedb-vso" \
  bound_service_account_namespaces="spicedb" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 5. Wait for the rendered K8s Secret to exist.
echo ">>> Waiting for VSO to render spicedb-config-vso (~30s)"
for _ in {1..60}; do
  if kubectl -n "$NS_SPICEDB" get secret spicedb-config-vso >/dev/null 2>&1; then
    echo "    spicedb-config-vso rendered"
    break
  fi
  sleep 1
done

if ! kubectl -n "$NS_SPICEDB" get secret spicedb-config-vso >/dev/null 2>&1; then
  echo "ERROR: spicedb-config-vso Secret was not rendered within 60s" >&2
  echo "       Check VSO logs: kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=50" >&2
  exit 1
fi

# Verify rendered Secret has the right keys
KEYS=$(kubectl -n "$NS_SPICEDB" get secret spicedb-config-vso -o jsonpath='{.data}' | grep -oE 'preshared_key|datastore_uri' | sort -u | tr '\n' ' ')
if [[ "$KEYS" != *"preshared_key"* || "$KEYS" != *"datastore_uri"* ]]; then
  echo "ERROR: spicedb-config-vso missing required keys. Got: $KEYS" >&2
  exit 1
fi
echo "    keys present: preshared_key, datastore_uri"

# 6. Update the SpiceDBCluster CR.
echo ">>> Patching SpiceDBCluster secretName: spicedb-config -> spicedb-config-vso"
kubectl -n "$NS_SPICEDB" patch spicedbcluster spicedb \
  --type=merge \
  -p '{"spec":{"secretName":"spicedb-config-vso"}}'

# 7. Wait for the operator to roll the Deployment.
echo ">>> Waiting for SpiceDB Deployment rollout (operator may take ~30s to react)"
sleep 5
kubectl -n "$NS_SPICEDB" rollout status deployment/spicedb-spicedb --timeout=240s

# 8. Verify pod Ready
READY=$(kubectl -n "$NS_SPICEDB" get pod -l authzed.com/cluster=spicedb -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
[[ "$READY" == "true" ]] && echo "✓ SpiceDB pod Ready" || { echo "SpiceDB pod NOT Ready" >&2; exit 1; }

cat <<'EOF'

✓ SpiceDB now consumes spicedb-config-vso (rendered by VSO from OpenBao).

  OpenBao path: secret/data/spicedb/config
  K8s rendered: spicedb/spicedb-config-vso (refreshed every 60s)
  CR secretName: spicedb-config-vso

The legacy spicedb-config Secret is still in place. After ≥10 min of soak
(SpiceDB stable, no restart loops), you can delete it:
  kubectl -n spicedb delete secret spicedb-config

To rotate the PSK in the future: edit secret/spicedb/config in OpenBao;
VSO will refresh spicedb-config-vso within 60s, but SpiceDB needs a pod
restart to pick up a new PSK (it's read at startup).

To rotate the Postgres password: when CNPG rotates secforge-spicedb-db-app,
re-run a small migration script that pulls the new password and updates
secret/spicedb/config in OpenBao. Or convert datastore_uri to use the
OpenBao database engine for dynamic creds (Phase 5.7 follow-up).
EOF
