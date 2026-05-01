#!/usr/bin/env bash
# Idempotent provisioner for the OpenBao OIDC client in Keycloak's
# `platform` realm.
#
# What this creates / ensures (all idempotent):
#   - Client `openbao` (confidential, OIDC, standard flow only)
#   - Realm role `platform_admin` (target for OpenBao admin policy)
#   - User `jason.upole` (or whoever — see KEYCLOAK_OPENBAO_ADMIN env)
#       has the platform_admin role assigned
#   - Default client scopes include `roles` (Keycloak's built-in scope
#       that emits `realm_access.roles` in access + ID tokens — that's
#       the claim OpenBao's bound_claims rule matches against)
#
# What this prints to STDOUT:
#   - The client_secret (ONCE). Capture it; pass to the OpenBao OIDC
#     configure script.
#
# Usage:
#   KCADM_USER=jaupole \
#   KCADM_PASSWORD='your-master-realm-pw' \
#   KCADM_TOTP=123456 \
#   bash infrastructure/keycloak/clients/openbao.sh
#
# Why TOTP is required: jaupole is enrolled in TOTP per ADR-0007. The
# code is good for ~30s; if the script fails on auth, re-run with a
# fresh code.

set -euo pipefail

NS=keycloak
POD=keycloak-0
REALM=platform
CLIENT_ID=openbao
PLATFORM_USER="${KEYCLOAK_OPENBAO_ADMIN:-jason.upole}"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

for v in KCADM_USER KCADM_PASSWORD; do
    [ -z "${!v:-}" ] && { red "env $v is required"; exit 1; }
done

# kcadm wrapper. Runs inside the keycloak-0 pod against the in-pod API.
kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# ─── 1. Authenticate ────────────────────────────────────────────────
green "==> kcadm config credentials (user=$KCADM_USER, master realm)"
# kcadm.sh has no --otp flag. Two cases:
#   (a) realm's direct-grant flow does not enforce OTP → plain
#       password works
#   (b) it does enforce OTP → Keycloak parses the trailing 6 digits
#       of the password as the TOTP code (ROPC convention)
# We try (a) first, then (b) if KCADM_TOTP was provided.
auth_ok=0
if kcadm config credentials \
        --server http://localhost:8080 \
        --realm master \
        --user "$KCADM_USER" \
        --password "$KCADM_PASSWORD" >/dev/null 2>&1; then
    green "    auth ok (password only)"
    auth_ok=1
elif [ -n "${KCADM_TOTP:-}" ]; then
    yellow "    password-only refused; trying password+TOTP concatenation"
    if kcadm config credentials \
            --server http://localhost:8080 \
            --realm master \
            --user "$KCADM_USER" \
            --password "${KCADM_PASSWORD}${KCADM_TOTP}" >/dev/null 2>&1; then
        green "    auth ok (password+TOTP)"
        auth_ok=1
    fi
fi
if [ "$auth_ok" -ne 1 ]; then
    red "kcadm auth failed. If you saw 'Invalid user credentials':"
    red "  - re-run with a fresh KCADM_TOTP (codes expire after ~30s)"
    red "  - confirm the password is current"
    red "  - or temporarily disable the direct-grant OTP requirement"
    red "    on the master realm via admin UI"
    exit 1
fi

# ─── 2. Create or update the openbao client ─────────────────────────
green "==> ensure openbao client in $REALM realm"

EXISTING=$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
    --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1 || true)

# Build the client representation. Mirrors the spec from CHECKPOINT 3.
CLIENT_JSON='{
  "clientId": "openbao",
  "name": "OpenBao",
  "description": "OIDC federation for OpenBao platform-admin login",
  "enabled": true,
  "rootUrl": "https://bao.secforge.local",
  "baseUrl": "https://bao.secforge.local",
  "redirectUris": [
    "https://bao.secforge.local/ui/vault/auth/oidc/oidc/callback",
    "https://bao.secforge.local/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "webOrigins": ["https://bao.secforge.local"],
  "clientAuthenticatorType": "client-secret",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": true,
  "protocol": "openid-connect",
  "fullScopeAllowed": false,
  "attributes": {
    "post.logout.redirect.uris": "https://bao.secforge.local",
    "pkce.code.challenge.method": "S256",
    "use.refresh.tokens": "true",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "user.info.signed.response.alg": "RS256",
    "client_credentials.use_refresh_token": "false",
    "use.jwks.url": "false"
  },
  "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
  "optionalClientScopes": ["offline_access", "address", "phone", "microprofile-jwt"]
}'

# Stage the JSON inside the pod for `kcadm -f`.
kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c 'cat > /tmp/openbao-client.json' <<<"$CLIENT_JSON"

if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/openbao-client.json
    INTERNAL_ID="$EXISTING"
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/openbao-client.json
    INTERNAL_ID=$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
        --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)
fi

# ─── 3. Read or regenerate the client_secret ────────────────────────
green "==> client_secret"
SECRET_JSON=$(kcadm get "clients/$INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null || true)
SECRET=$(jq -r '.value // empty' <<<"$SECRET_JSON")
if [ -z "$SECRET" ]; then
    yellow "    no secret yet — regenerating"
    SECRET_JSON=$(kcadm create "clients/$INTERNAL_ID/client-secret" -r "$REALM" -i 2>&1 | tail -1)
    SECRET=$(jq -r '.value // empty' <<<"$SECRET_JSON")
fi

# ─── 4. Create realm role platform_admin (idempotent) ───────────────
green "==> ensure realm role platform_admin in $REALM"
if ! kcadm get "roles/platform_admin" -r "$REALM" >/dev/null 2>&1; then
    kcadm create roles -r "$REALM" \
        -s name=platform_admin \
        -s description="Maps to OpenBao admin policy via OIDC bound_claims"
    green "    created"
else
    yellow "    already exists"
fi

# ─── 5. Assign platform_admin to PLATFORM_USER ──────────────────────
green "==> assign platform_admin to user $PLATFORM_USER"
# add-roles is idempotent — re-assigning a role the user already has
# is a no-op (returns 204).
kcadm add-roles -r "$REALM" \
    --uusername "$PLATFORM_USER" \
    --rolename platform_admin >/dev/null 2>&1 || \
    yellow "    (user may already have role; continuing)"

# ─── 6. Print the secret. Capture it once. ──────────────────────────
yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " openbao OIDC client_secret (capture now — printed once):"
yellow ""
yellow "   $SECRET"
yellow ""
yellow " Pipe directly into the OpenBao configure step:"
yellow ""
yellow "   BAO_TOKEN=<your-root-token> CLIENT_SECRET='$SECRET' \\"
yellow "       bash infrastructure/openbao/configure-auth-oidc.sh"
yellow "═════════════════════════════════════════════════════════════════════"
