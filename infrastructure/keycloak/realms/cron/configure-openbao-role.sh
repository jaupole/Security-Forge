#!/usr/bin/env bash
# Phase 7d.1.b — configure the OpenBao JWT role for bff-key-rotator.
#
# Mirrors the helloworld-bff role shape (audience=openbao, bound to
# the workload SPIFFE-ID, token_ttl=1h, token_policies=bff-key-rotator).
# Idempotent: `bao write` overwrites the role on each run.
#
# Pre-conditions:
#   - infrastructure/openbao/policies/bff-key-rotator.hcl already loaded
#     (re-run infrastructure/openbao/load-policies.sh if not).
#   - SPIRE has issued an SVID covering ns/app/sa/bff-key-rotator (the
#     namespace-scoped ClusterSPIFFEID covering `app` already covers it
#     once the ServiceAccount is applied; verify via
#     `kubectl get clusterspiffeid -A`).
#
# Auth: BAO_TOKEN must be a token with capabilities on auth/jwt/role/*
# (admin-tier).

set -euo pipefail

NS=openbao
POD=openbao-0

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use the admin OIDC token (host-side):\n" >&2
    printf "  bao login -method=oidc role=admin\n" >&2
    printf "  export BAO_TOKEN=\$(bao print token)\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

green "==> sanity-check: bff-key-rotator policy loaded?"
if ! bao bao policy read bff-key-rotator >/dev/null 2>&1; then
    printf "policy bff-key-rotator not found in OpenBao. Run:\n" >&2
    printf "  bash infrastructure/openbao/load-policies.sh\n" >&2
    exit 1
fi
green "    policy exists"

green "==> writing auth/jwt/role/bff-key-rotator"
bao bao write auth/jwt/role/bff-key-rotator \
    role_type=jwt \
    bound_audiences=openbao \
    user_claim=sub \
    bound_subject="spiffe://secforge.local/ns/app/sa/bff-key-rotator" \
    token_policies=bff-key-rotator \
    token_ttl=1h \
    token_max_ttl=1h 2>&1 | tail -3

green ""
green "Role configured. Verify with:"
green "  bao read auth/jwt/role/bff-key-rotator"
green ""
green "Next: kubectl apply -f infrastructure/keycloak/realms/cron/01-rotate-bff-key.yaml"
