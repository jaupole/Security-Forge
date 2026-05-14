#!/usr/bin/env bash
# 05i — Configure OpenBao OIDC auth method federated to Keycloak.
#
# Maps the platform-realm user `jason.upole` (or whatever the operator set
# in 05g) to the `admin` OpenBao policy. Login flow: browse to OpenBao UI,
# select "Sign in with OIDC", land at Keycloak, complete TOTP, return with
# admin role granted.
#
# Pre-conditions:
#   - 05c ran (openbao-root-token-tmp Secret + admin policy + transit/kv-v2 + kubernetes auth)
#   - 05g ran (platform realm imported)
#   - 05h ran (openbao OIDC client + Secret keycloak-openbao-client-secret)
#   - Operator created jason.upole user with TOTP enrolled
#
# Idempotent.

set -euo pipefail

NS=openbao
POD=openbao-0

# shellcheck disable=SC1091
set -a; source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)/../globals.env"; set +a

# Operator-set platform admin username (must match the user created via Keycloak admin UI).
PLATFORM_ADMIN="${KEYCLOAK_OPENBAO_ADMIN:-jason.upole}"

# Pre-flight: secrets
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  echo "ERROR: openbao-root-token-tmp Secret not found." >&2; exit 1
fi
if ! kubectl -n "$NS" get secret keycloak-openbao-client-secret >/dev/null 2>&1; then
  echo "ERROR: keycloak-openbao-client-secret Secret not found. Run 05h first." >&2; exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
CLIENT_ID=$(kubectl -n "$NS" get secret keycloak-openbao-client-secret -o jsonpath='{.data.client_id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n "$NS" get secret keycloak-openbao-client-secret -o jsonpath='{.data.client_secret}' | base64 -d)

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. Enable OIDC auth method
echo ">>> Enabling oidc auth method"
if bao bao auth list -format=json 2>/dev/null | grep -q '"oidc/":'; then
  echo "    already enabled"
else
  bao bao auth enable oidc 2>&1 | tail -1
fi

# 2. Configure the OIDC method.
# Note: we do NOT pass oidc_discovery_ca_pem because Keycloak's TLS cert is a
# real Let's Encrypt cert — the openbao container's system CA bundle trusts it.
echo ">>> Configuring oidc auth (Keycloak platform realm)"
bao bao write auth/oidc/config \
  oidc_discovery_url="https://auth.${DOMAIN}/realms/platform" \
  oidc_client_id="$CLIENT_ID" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role=admin 2>&1 | tail -2

# 3. Build the admin role JSON, stage in pod, apply.
ADMIN_ROLE_JSON=$(cat <<EOF
{
  "role_type": "oidc",
  "user_claim": "preferred_username",
  "allowed_redirect_uris": [
    "https://bao.${DOMAIN}/ui/vault/auth/oidc/oidc/callback",
    "https://bao.${DOMAIN}/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "policies": ["admin"],
  "oidc_scopes": ["openid", "profile", "email"],
  "bound_claims_type": "string",
  "bound_claims": {
    "preferred_username": ["${PLATFORM_ADMIN}"]
  },
  "ttl": "8h",
  "max_ttl": "24h"
}
EOF
)
echo "$ADMIN_ROLE_JSON" | kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c 'cat > /tmp/oidc-role-admin.json'

echo ">>> Writing OIDC role: admin (preferred_username=$PLATFORM_ADMIN -> admin policy)"
bao bao write auth/oidc/role/admin @/tmp/oidc-role-admin.json 2>&1 | tail -2

# 4. Optional reader role (anyone in the platform realm logging in as "reader" gets reader policy).
READER_ROLE_JSON=$(cat <<'EOF'
{
  "role_type": "oidc",
  "user_claim": "preferred_username",
  "allowed_redirect_uris": [
    "https://bao.${DOMAIN}/ui/vault/auth/oidc/oidc/callback",
    "https://bao.${DOMAIN}/oidc/callback"
  ],
  "policies": ["reader"],
  "oidc_scopes": ["openid", "profile", "email"]
}
EOF
)
# Substitute ${DOMAIN} in the reader role
READER_ROLE_JSON="${READER_ROLE_JSON//\$\{DOMAIN\}/$DOMAIN}"
echo "$READER_ROLE_JSON" | kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c 'cat > /tmp/oidc-role-reader.json'

echo ">>> Writing OIDC role: reader (any platform-realm user -> reader policy)"
bao bao write auth/oidc/role/reader @/tmp/oidc-role-reader.json 2>&1 | tail -2

unset ROOT_TOKEN CLIENT_SECRET ADMIN_ROLE_JSON READER_ROLE_JSON

# Cleanup staged files in pod
kubectl exec -n "$NS" "$POD" -c openbao -- rm -f /tmp/oidc-role-admin.json /tmp/oidc-role-reader.json 2>/dev/null || true

cat <<EOF

✓ OpenBao OIDC auth method configured.

Login flow:
  1. Browse https://bao.${DOMAIN}
  2. Click "Sign in with OIDC Provider"
  3. Leave Role BLANK (defaults to admin) — or type 'reader' for read-only
  4. Click Sign in -> redirects to Keycloak
  5. Sign in as ${PLATFORM_ADMIN} + TOTP
  6. Land back at OpenBao with admin policy attached

After login works, you can revoke the initial root token:
  bao bao token revoke <initial-root-token>
(Don't do this until you've verified OIDC login works for $PLATFORM_ADMIN)
EOF
