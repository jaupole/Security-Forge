#!/usr/bin/env bash
# Phase 5.4 + 5.8 — enable Kubernetes and JWT (SPIRE) auth methods.
#
# OIDC (Keycloak) is intentionally NOT done here; it's blocked on the
# manual creation of the `openbao` Keycloak client in the platform
# realm. After that, run configure-auth-oidc.sh.
#
# Pre-conditions:
#   - main OpenBao initialized + unsealed (Phase 5.3)
#   - secrets engines configured (Phase 5.7+5.11)
#   - SPIRE OIDC discovery provider Ready in spire ns

set -euo pipefail
NS=openbao
POD=openbao-0

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Pass the main OpenBao initial root token:\n"
    printf "  BAO_TOKEN=s.XXX bash configure-auth-k8s-jwt.sh\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# ─── Kubernetes auth ─────────────────────────────────────────────────
green "==> enable kubernetes auth"
if bao bao auth list -format=json 2>/dev/null | grep -q '"kubernetes/":'; then
    green "    already enabled"
else
    bao bao auth enable kubernetes 2>&1 | tail -1
fi

green "==> configure kubernetes auth (kubernetes_host + CA from in-pod files)"
# OpenBao runs inside the cluster; it reaches the API server via the
# in-cluster Service kubernetes.default.svc, with the CA bundle from
# its own ServiceAccount projection.
bao bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    disable_local_ca_jwt="false" 2>&1 | tail -1

# ─── JWT auth (SPIRE) ────────────────────────────────────────────────
green "==> enable jwt auth"
if bao bao auth list -format=json 2>/dev/null | grep -q '"jwt/":'; then
    green "    already enabled"
else
    bao bao auth enable jwt 2>&1 | tail -1
fi

green "==> configure jwt auth (jwks_url → SPIRE OIDC discovery)"
bao bao write auth/jwt/config \
    oidc_discovery_url="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
    oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    bound_issuer="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
    default_role="" 2>&1 | tail -3
# Note: SPIRE's OIDC endpoint cert is mkcert-issued; we don't have
# the mkcert CA mounted in OpenBao. For local edition we set
# oidc_discovery_ca_pem to the in-cluster API server CA (which is the
# same CA cluster pods already trust for in-cluster TLS — works because
# Docker Desktop's API server uses the same CA chain that the spire
# OIDC discovery provider's cert is signed against). If that fails,
# fall back to oidc_discovery_ca_pem set to the mkcert CA bundle —
# but locally the API CA path tends to work for ad-hoc workloads.

green ""
green "Kubernetes + JWT auth enabled. Next:"
green "  - manually create Keycloak openbao OIDC client (instructions in chat)"
green "  - then bash configure-auth-oidc.sh CLIENT_SECRET=<from-keycloak>"
green ""
green "To create the OIDC client via kcadm with your platform-realm admin"
green "credentials (jaupole + TOTP), see docs/03-runbooks/openbao-recovery.md."
