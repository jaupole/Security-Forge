#!/usr/bin/env bash
# Phase 7d Item 4 — bootstrap Prometheus → OpenBao /v1/sys/metrics
# bearer-token authentication.
#
# What this does:
#   1. Loads infrastructure/openbao/policies/metrics-policy.hcl into the
#      main OpenBao (idempotent).
#   2. Mints a periodic token (period=720h) bound to metrics-policy.
#      Periodic tokens auto-refresh their TTL on every USE. With a 30s
#      Prometheus scrape interval, the token is effectively immortal as
#      long as Prometheus is up. Cold-pause >30d expires it; recovery
#      = re-run this script.
#   3. Writes the token to K8s Secret `openbao-metrics-token` in the
#      `openbao` namespace, which the ServiceMonitor's
#      `bearerTokenSecret.name` field references. (The Prometheus
#      Operator resolves `bearerTokenSecret` in the SAME namespace as
#      the ServiceMonitor, NOT the Prometheus pod's ns.)
#
# Pre-conditions:
#   - main OpenBao is unsealed and reachable
#   - BAO_TOKEN exported with admin-tier capabilities
#
# Idempotent: re-running rotates the token (issues a new one + overwrites
# the K8s Secret). Old token is revoked separately if you want to be
# strict — periodic tokens only need rotation if compromised, since
# their authorization is read-only on sys/metrics and they auto-refresh.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/openbao/configure-metrics-auth.sh

set -euo pipefail

NS=openbao
POD=openbao-0
# The K8s Secret holding the metrics bearer token MUST live in the same
# namespace as the ServiceMonitor (per Prometheus Operator's
# `bearerTokenSecret` resolution), which is `openbao`. We don't put it
# in observability ns because the operator won't cross-ns-read.
SECRET_NS=openbao
SECRET_NAME=openbao-metrics-token
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use the admin OIDC token:\n" >&2
    printf "  bao login -method=oidc role=admin\n" >&2
    printf "  export BAO_TOKEN=\$(bao print token)\n" >&2
    exit 1
fi

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# 1. Load the metrics policy.
green "==> bao policy write metrics-policy"
kubectl exec -i -n "$NS" "$POD" -c openbao -- \
    /bin/sh -c "cat > /tmp/metrics-policy.hcl" <"$HERE/policies/metrics-policy.hcl"
bao bao policy write metrics-policy /tmp/metrics-policy.hcl 2>&1 | tail -1
kubectl exec -n "$NS" "$POD" -c openbao -- rm -f /tmp/metrics-policy.hcl >/dev/null 2>&1 || true

# 2. Mint the periodic token. -no-default-policy strips the `default`
#    policy that's auto-attached otherwise — we want metrics-policy and
#    nothing else.
green "==> minting periodic metrics token (period=720h)"
TOKEN_OUT=$(bao bao token create \
    -policy=metrics-policy \
    -no-default-policy \
    -period=720h \
    -display-name=prometheus-metrics \
    -format=json 2>/dev/null)
TOKEN=$(printf '%s' "$TOKEN_OUT" | jq -r '.auth.client_token // empty')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    red "token mint failed. raw output:"
    red "$TOKEN_OUT"
    exit 1
fi

# 3. Write to K8s Secret in same ns as the ServiceMonitor (openbao).
#    `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`
#    is the standard idempotent idiom.
green "==> writing K8s Secret ${SECRET_NS}/${SECRET_NAME}"
kubectl create secret generic "$SECRET_NAME" \
    --namespace="$SECRET_NS" \
    --from-literal=token="$TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - \
        secforge.platform/component=openbao-metrics \
        app.kubernetes.io/managed-by=configure-metrics-auth-script \
        --dry-run=client -o yaml \
    | kubectl apply -f -
unset TOKEN TOKEN_OUT

green ""
green "Phase 7d Item 4 — metrics auth bootstrap complete."
green ""
green "Next:"
green "  - kubectl apply -f infrastructure/openbao/09-servicemonitor.yaml"
green "  - bash infrastructure/openbao/apply-main.sh   # re-renders the listener block"
green "    (un-comment the unauthenticated_metrics_access=false flip in 04-openbao-values.yaml first)"
green ""
green "Verify scraping post-flip:"
green "  kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &"
green "  curl -s 'http://localhost:9090/api/v1/query?query=up{job=\"openbao\"}' | jq"
green ""
