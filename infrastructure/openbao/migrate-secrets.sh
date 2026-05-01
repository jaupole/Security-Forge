#!/usr/bin/env bash
# Phase 5.10 — migrate non-TLS Phase 1-4 secrets into OpenBao KV-v2.
#
# What gets moved:
#   secret/data/spicedb/preshared-key            ← spicedb/spicedb-config[preshared_key]
#   secret/data/keycloak/clients/<client_id>     ← app/bff-jwt-<client_id>[private.pem,public.pem]
#
# What stays as-is (TLS keypairs, cert-manager-managed):
#   keycloak/auth-public-tls, auth-admin-tls
#   spicedb/spicedb-grpc-tls
#   openbao/openbao-tls, openbao-seal-tls
#   secforge-*-db-{ca,server,replication,app}
#
# Phase 6+ wires consumers to fetch from OpenBao via SPIRE-bound JWT
# auth (Vault Secrets Operator OR direct API). Until then, the K8s
# Secrets remain authoritative for those consumers — this is purely
# replication, not a cutover.
#
# Idempotent: re-running overwrites the existing values (KV-v2 versions
# the change rather than destroying history).
#
# Token: uses the kubernetes auth admin-break-glass role. No external
# admin token required.

set -euo pipefail
NS=openbao
POD=openbao-0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Mint a fresh admin token via the break-glass kubernetes role.
SA_JWT=$(kubectl exec -n "$NS" "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ADMIN_TOKEN=$(kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login role=admin-break-glass jwt="$SA_JWT" \
    | jq -r '.auth.client_token')
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    red "failed to mint admin-break-glass token"; exit 1
fi

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" "$@"
}

# ─── 1. SpiceDB pre-shared key ───────────────────────────────────────
green "==> migrate SpiceDB pre-shared key → secret/data/spicedb/preshared-key"
SPICEDB_PSK=$(kubectl get secret -n spicedb spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)
bao bao kv put secret/spicedb/preshared-key \
    preshared_key="$SPICEDB_PSK" \
    source="phase-1-cnpg-bootstrap" \
    rotation_owner="spicedb-operator" 2>&1 | tail -3
unset SPICEDB_PSK

# ─── 2. Phase 3.5 BFF private_key_jwt keypairs ───────────────────────
green "==> migrate BFF private_key_jwt keypairs"
for client_id in helloworld-bff proposal-forge-bff project-tracker-bff pm-bff; do
    SECRET=app/bff-jwt-$client_id
    if ! kubectl get secret -n app "bff-jwt-$client_id" >/dev/null 2>&1; then
        red "  skip: $SECRET missing in cluster"; continue
    fi
    PRIV=$(kubectl get secret -n app "bff-jwt-$client_id" -o jsonpath='{.data.private\.pem}' | base64 -d)
    PUB=$( kubectl get secret -n app "bff-jwt-$client_id" -o jsonpath='{.data.public\.pem}'  | base64 -d)
    # Stage the multi-line PEMs in the pod for `bao kv put @file` style is
    # not supported for KV; we use stdin-piped JSON instead.
    JSON=$(jq -n \
        --arg priv "$PRIV" --arg pub "$PUB" --arg cid "$client_id" \
        '{private_pem: $priv, public_pem: $pub, client_id: $cid, source: "phase-3.5"}')
    kubectl exec -i -n "$NS" "$POD" -c openbao -- \
        sh -c "cat > /tmp/migrate-$client_id.json" <<<"$JSON"
    bao bao kv put "secret/keycloak/clients/$client_id" "@/tmp/migrate-$client_id.json" 2>&1 | tail -1
    unset PRIV PUB JSON
done

# ─── 3. Verify the migrated paths ────────────────────────────────────
green "==> verify"
bao bao kv list secret/spicedb 2>&1 | tail -5
bao bao kv list secret/keycloak/clients 2>&1 | tail -10

green ""
green "Phase 5.10 done. K8s Secrets remain authoritative until Phase 6"
green "wires Vault Secrets Operator (or direct OpenBao API) for consumers."
