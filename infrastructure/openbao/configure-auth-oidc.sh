#!/usr/bin/env bash
# Phase 5.4 (continuation) — configure OpenBao OIDC auth federated to Keycloak.
#
# Pre-conditions:
#   - main OpenBao auth methods kubernetes + jwt already configured
#   - You created an `openbao` confidential OIDC client in the Keycloak
#     `platform` realm (see CHECKPOINT 3 instructions in chat).
#   - You have the client_secret value in env CLIENT_SECRET.
#
# Usage:
#   BAO_TOKEN=s.XXX CLIENT_SECRET="..." bash configure-auth-oidc.sh

set -euo pipefail
NS=openbao
POD=openbao-0

# Single-user binding for the admin role (7.0.b workaround). Override via env
# if the platform admin username changes; otherwise defaults to jason.upole
# (same default as infrastructure/keycloak/clients/openbao.sh).
PLATFORM_USER="${KEYCLOAK_OPENBAO_ADMIN:-jason.upole}"

if [ -z "${BAO_TOKEN:-}" ]; then echo "BAO_TOKEN not set" >&2; exit 1; fi
if [ -z "${CLIENT_SECRET:-}" ]; then echo "CLIENT_SECRET not set" >&2; exit 1; fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# Get the mkcert CA (Keycloak serves with that).
MKCERT_CA=$(kubectl get clusterissuer mkcert-issuer -o jsonpath='{.spec.ca.secretName}')
KC_CA=$(kubectl get secret -n cert-manager "$MKCERT_CA" -o jsonpath='{.data.tls\.crt}' | base64 -d)
echo "$KC_CA" | kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c "cat > /tmp/mkcert-ca.pem"

# Enable + configure oidc.
green "==> enable oidc auth"
if bao bao auth list -format=json 2>/dev/null | grep -q '"oidc/":'; then
    green "    already enabled"
else
    bao bao auth enable oidc 2>&1 | tail -1
fi

green "==> configure oidc auth (Keycloak platform realm)"
# default_role=admin so the user can leave the Role field blank.
# bound_claims on the admin role restricts entry to users with the
# Keycloak platform_admin realm role.
bao bao write auth/oidc/config \
    oidc_discovery_url="https://auth.secforge.local/realms/platform" \
    oidc_discovery_ca_pem=@/tmp/mkcert-ca.pem \
    oidc_client_id=openbao \
    oidc_client_secret="$CLIENT_SECRET" \
    default_role=admin 2>&1 | tail -2

# Map a single Keycloak user → admin OpenBao policy.
#
# WORKAROUND (Phase 5 follow-up #1 / Phase 7.0.b carry-in): the intended
# binding is `realm_access/roles ⊇ platform_admin`, but Keycloak's
# userinfo response (or whatever path OpenBao captures) doesn't actually
# surface the `realm_access.roles` claim despite the `roles` default
# scope and Add-to-ID-token+userinfo mapper being enabled. Until 7.0.b
# debugs and fixes the claim plumbing (gated on Loki live so we can
# read Keycloak/OpenBao logs side-by-side), bind on `preferred_username`
# as a single-user workaround. PLAN.md tracks the 90-day fallback
# escalation trigger 2026-07-29.
#
# `bao write` parses kv-pair args as scalar values; nested JSON has to
# come via @file. We stage a JSON spec in /tmp inside the pod.
green "==> auth/oidc/role/admin (preferred_username=$PLATFORM_USER → admin policy; 7.0.b workaround)"
ADMIN_ROLE_JSON="{
  \"role_type\": \"oidc\",
  \"user_claim\": \"preferred_username\",
  \"allowed_redirect_uris\": [
    \"https://bao.secforge.local/ui/vault/auth/oidc/oidc/callback\",
    \"https://bao.secforge.local/oidc/callback\",
    \"http://localhost:8250/oidc/callback\"
  ],
  \"policies\": [\"admin\"],
  \"oidc_scopes\": [\"openid\", \"profile\", \"email\"],
  \"bound_claims_type\": \"string\",
  \"bound_claims\": {
    \"preferred_username\": [\"$PLATFORM_USER\"]
  },
  \"ttl\": \"8h\",
  \"max_ttl\": \"24h\"
}"
kubectl exec -i -n "$NS" "$POD" -c openbao -- \
    sh -c 'cat > /tmp/oidc-role-admin.json' <<<"$ADMIN_ROLE_JSON"
bao bao write auth/oidc/role/admin @/tmp/oidc-role-admin.json 2>&1 | tail -2

# A second role (reader) — opt-in via the Role field — for any
# platform-realm user without platform_admin. Read their own KV
# namespace only.
green "==> auth/oidc/role/reader (any platform-realm user → reader policy)"
READER_ROLE_JSON='{
  "role_type": "oidc",
  "user_claim": "preferred_username",
  "allowed_redirect_uris": [
    "https://bao.secforge.local/ui/vault/auth/oidc/oidc/callback",
    "https://bao.secforge.local/oidc/callback"
  ],
  "policies": ["reader"],
  "oidc_scopes": ["openid", "profile", "email"]
}'
kubectl exec -i -n "$NS" "$POD" -c openbao -- \
    sh -c 'cat > /tmp/oidc-role-reader.json' <<<"$READER_ROLE_JSON"
bao bao write auth/oidc/role/reader @/tmp/oidc-role-reader.json 2>&1 | tail -2

green ""
green "OIDC auth wired. Login flow:"
green "  1. open https://bao.secforge.local"
green "  2. click 'Sign in with OIDC Provider'"
green "  3. leave the Role field BLANK (defaults to admin)"
green "  4. click Sign in → bounce to Keycloak → log in with TOTP"
green "  5. land back at OpenBao with the admin policy"
green ""
green "Login as a non-platform_admin user: type 'reader' in the Role field."
