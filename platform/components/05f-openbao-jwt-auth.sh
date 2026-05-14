#!/usr/bin/env bash
# 05f — Configure OpenBao JWT-SPIFFE auth method.
#
# Workloads with SPIFFE-bound identities (any pod with a SPIRE-issued JWT-SVID)
# can authenticate to OpenBao via this method. Per-component roles get added
# incrementally as the components deploy.
#
# Pre-conditions:
#   - 05c (kubernetes auth + policies + engines) ran
#   - SPIRE OIDC discovery provider Ready (Gap #10 fix applied)
#   - openbao-root-token-tmp Secret in openbao ns
#
# Idempotent.

set -euo pipefail

NS=openbao
POD=openbao-0

# Pre-flight: root token Secret
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  echo "ERROR: openbao-root-token-tmp Secret not found." >&2
  exit 1
fi
ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

# Pre-flight: SPIRE OIDC discovery up
if ! kubectl get svc -n spire spire-spiffe-oidc-discovery-provider >/dev/null 2>&1; then
  echo "ERROR: SPIRE OIDC discovery service not found in spire ns." >&2
  echo "       Re-enable in platform/values/spire.yaml + helm upgrade." >&2
  exit 1
fi

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. Stage SPIRE upstream CA cert into the openbao pod for TLS validation
#    of the OIDC discovery endpoint.
echo ">>> Staging SPIRE upstream CA cert into openbao-0:/tmp/spire-ca.pem"
SPIRE_CA=$(kubectl -n spire get secret spire-upstream-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [[ -z "$SPIRE_CA" ]]; then
  echo "ERROR: could not read spire-upstream-ca cert from spire ns" >&2
  exit 1
fi
echo "$SPIRE_CA" | kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c 'cat > /tmp/spire-ca.pem'

# 2. Enable JWT auth method
echo ">>> Enabling jwt auth method"
if bao bao auth list -format=json 2>/dev/null | grep -q '"jwt/":'; then
  echo "    already enabled"
else
  bao bao auth enable jwt 2>&1 | tail -1
fi

# 3. Configure JWT auth with SPIRE OIDC discovery + SPIRE upstream CA
echo ">>> Configuring jwt auth (oidc_discovery_url -> SPIRE OIDC, ca -> spire-upstream-ca)"
bao bao write auth/jwt/config \
  oidc_discovery_url="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
  oidc_discovery_ca_pem=@/tmp/spire-ca.pem \
  bound_issuer="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
  default_role="" 2>&1 | tail -3

# 4. Capture the JWT auth method's accessor for any policy that needs to
#    template against identity.entity.aliases.<accessor>... (e.g., app-template.hcl)
JWT_ACCESSOR=$(bao bao auth list -format=json 2>/dev/null | jq -r '."jwt/".accessor')
echo
echo ">>> JWT auth accessor: $JWT_ACCESSOR"
echo "    (used to template app-template.hcl when JWT-bound apps deploy)"

unset ROOT_TOKEN

cat <<EOF

✓ JWT-SPIFFE auth method enabled and configured.

  Discovery URL: https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local
  CA validation: spire-upstream-ca (cert mounted at /tmp/spire-ca.pem in openbao-0)
  Accessor:      $JWT_ACCESSOR

Per-app roles aren't created yet (roles bind a SPIFFE-ID to an OpenBao policy
+ TTL). Add them per-component as workloads come online — example:
  bao write auth/jwt/role/<app-name> \\
    bound_audiences=openbao \\
    user_claim=sub \\
    bound_subject=spiffe://secforge.platform/ns/app/sa/<app-name> \\
    token_metadata=app=<app-name> \\
    token_policies=app-template \\
    token_ttl=15m \\
    token_max_ttl=1h

Next: bash 05g-openbao-oidc-auth.sh (after Keycloak realm + openbao client are set up)
EOF
