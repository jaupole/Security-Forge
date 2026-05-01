#!/usr/bin/env bash
# Phase 6.8 — apply BFF deployment manifests.
# Run after `apps/helloworld-bff/build.sh` has loaded the image into
# the Docker Desktop containerd store as local/helloworld-bff:0.1.0.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. OpenBao prerequisites: jwt-auth role + KV path. Phase 5.10 wrote the
#    KV value; the role is part of Phase 5 configure-auth-k8s-jwt.sh.
#    We sanity-check that the role exists. If you are bootstrapping a
#    fresh cluster, run the Phase 5 scripts first.
green "==> sanity check: OpenBao jwt role helloworld-bff exists?"
NS=openbao; POD=openbao-0
SA_JWT=$(kubectl exec -n "$NS" "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ADMIN_TOKEN=$(kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login role=admin-break-glass jwt="$SA_JWT" \
    | jq -r '.auth.client_token')
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    red "could not mint admin-break-glass token"; exit 1
fi
if ! kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ADMIN_TOKEN" \
        bao read auth/jwt/role/helloworld-bff >/dev/null 2>&1; then
    red "OpenBao auth/jwt/role/helloworld-bff not found"
    red "run infrastructure/openbao/configure-auth-k8s-jwt.sh first"
    exit 1
fi
green "    role exists"

# 2. Apply manifests in order.
for f in 01-spiffe-helper-conf.yaml \
         02-deployment.yaml \
         03-service.yaml \
         04-ingress.yaml \
         05-networkpolicies.yaml; do
    green "==> kubectl apply -f $f"
    kubectl apply -f "$HERE/$f"
done

# 3. Wait for rollout.
green "==> waiting for rollout"
kubectl rollout status -n app deployment/helloworld-bff --timeout=120s

green ""
green "BFF deployed. Quick smoke test:"
green "  kubectl exec -n app deploy/helloworld-bff -- /helloworld-bff --version  # (no flag yet; will exit error — fine, just confirms binary runs)"
green "  curl -fsS https://app.secforge.local/healthz"
green ""
green "Login flow lives in Phase 6.9."
