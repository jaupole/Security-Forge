#!/usr/bin/env bash
# Phase 6.0.2 — verify OpenBao copies match the live K8s Secret values
# that Phase 5.10 replicated. Compares SHA-256 hashes only; no plaintext
# leaves the pod.
#
# Use this BEFORE the Phase 6.10b cutover deletes K8s Secret copies, and
# any time you suspect drift between OpenBao and the legacy K8s Secrets.
#
# Auth: kubernetes auth admin-break-glass role (same path as
# migrate-secrets.sh). No external token required.
#
# IMPORTANT: capture both sides into shell variables before hashing.
# `bao kv get -field=...` appends a trailing newline to its stdout, while
# `kubectl get -o jsonpath | base64 -d` does not. If you hash via pipes
# directly, you'll get false-positive drift on every PEM. Using $() to
# capture strips trailing newlines on both sides, making the comparison
# byte-accurate.
set -euo pipefail

NS=openbao
POD=openbao-0
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

SA_JWT=$(kubectl exec -n "$NS" "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ADMIN_TOKEN=$(kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login role=admin-break-glass jwt="$SA_JWT" \
    | jq -r '.auth.client_token')
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    red "failed to mint admin-break-glass token"; exit 1
fi

bao_get() {  # path field
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
        bao kv get -field="$2" "$1"
}
sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

DRIFT=0
verdict() {
    local label=$1 a=$2 b=$3
    if [ "$a" = "$b" ]; then
        green "  $label  MATCH ($a)"
    else
        red   "  $label  DRIFT  K8s=$a  OpenBao=$b"
        DRIFT=1
    fi
}

green "==> 1) SpiceDB preshared-key"
K8S_VAL=$(kubectl get secret -n spicedb spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)
BAO_VAL=$(bao_get secret/spicedb/preshared-key preshared_key)
verdict "preshared_key" "$(sha "$K8S_VAL")" "$(sha "$BAO_VAL")"

for client_id in helloworld-bff proposal-forge-bff project-tracker-bff pm-bff; do
    green "==> 2) BFF $client_id"
    K8S_VAL=$(kubectl get secret -n app "bff-jwt-$client_id" -o jsonpath='{.data.private\.pem}' | base64 -d)
    BAO_VAL=$(bao_get "secret/keycloak/clients/$client_id" private_pem)
    verdict "private.pem" "$(sha "$K8S_VAL")" "$(sha "$BAO_VAL")"

    K8S_VAL=$(kubectl get secret -n app "bff-jwt-$client_id" -o jsonpath='{.data.public\.pem}' | base64 -d)
    BAO_VAL=$(bao_get "secret/keycloak/clients/$client_id" public_pem)
    verdict "public.pem " "$(sha "$K8S_VAL")" "$(sha "$BAO_VAL")"
done

if [ $DRIFT -eq 0 ]; then
    green ""
    green "All Phase 5.10 secrets in sync. Safe to proceed with Phase 6.10b cutover."
else
    red ""
    red "Drift detected — re-run infrastructure/openbao/migrate-secrets.sh and rerun this verifier."
    exit 1
fi
