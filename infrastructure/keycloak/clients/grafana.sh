#!/usr/bin/env bash
# Phase 7.3 — Idempotent provisioner for the Grafana OIDC client in
# Keycloak's `platform` realm.
#
# Follows the Path A "clone the spike-token-exchange.sh service-account
# auth pattern" approach (see docs/03-runbooks/keycloak-client-
# provisioning.md). kcadm 26.x removed --otp; user-with-TOTP auth is
# not viable, so we authenticate as a per-task throwaway service-account
# client in the master realm.
#
# What this creates / ensures (idempotent):
#   - Client `grafana` in `platform` realm (confidential, client-secret,
#     standard flow, redirect to https://grafana.secforge.local/login/
#     generic_oauth, default scopes include `roles` so realm_access.roles
#     ships in tokens).
#   - Realm role `platform_admin` is assumed to already exist (created
#     in Phase 5 by openbao.sh). If missing, this script aborts — re-run
#     openbao.sh first.
#
# What this prints to STDOUT:
#   - The grafana client's client_secret (ONCE per regenerate; otherwise
#     the existing value). Capture and feed into the kube-prometheus-stack
#     Helm values via the openbao-rendered Secret (Phase 7.3 wiring).
#
# Prerequisites the OPERATOR must satisfy manually before first run:
#   1. Create a throwaway service-account client `kcadm-grafana-tmp` in
#      the master realm via the Keycloak admin UI:
#        - Client type: OpenID Connect
#        - Client ID: kcadm-grafana-tmp (the -tmp suffix is the migration-
#          time inventory grep target; see docs/03-runbooks/keycloak-
#          client-provisioning.md)
#        - Client authentication: ON
#        - Authentication flow: only "Service accounts roles"
#        - Service accounts roles: assign these client roles on
#          `platform-realm`:
#            view-realm, view-clients, query-clients, manage-clients
#   2. Capture the client_secret and pass via env KCADM_CLIENT_SECRET.
#
# Tear-down:
#   This script does NOT auto-delete the grafana client (it's a
#   permanent Phase 7 component). To delete the throwaway kcadm-grafana-
#   tmp client when the kcadm-admin migration phase lands, do it from
#   the master realm UI.
#
# Usage:
#   KCADM_CLIENT_SECRET='<from-master-realm-UI>' \
#       bash infrastructure/keycloak/clients/grafana.sh

set -euo pipefail

NS=keycloak
POD=keycloak-0
REALM=platform
CLIENT_ID=grafana
KCADM_CLIENT_ID=kcadm-grafana-tmp

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${KCADM_CLIENT_SECRET:-}" ] && {
    red "env KCADM_CLIENT_SECRET is required"
    red "  See script header — create kcadm-grafana-tmp in master realm UI first."
    exit 1
}

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# kcadm authenticates as kcadm-grafana-tmp service-account client in master.
kcadm_auth() {
    if kcadm config credentials \
            --server http://localhost:8080 --realm master \
            --client "$KCADM_CLIENT_ID" --secret "$KCADM_CLIENT_SECRET" \
            >/dev/null 2>&1; then
        green "    kcadm auth ok (client_credentials as $KCADM_CLIENT_ID)"
        return
    fi
    red "kcadm auth failed as client $KCADM_CLIENT_ID"
    red "  - confirm the client exists in master realm with Service-Accounts-Roles enabled"
    red "  - confirm the assigned client roles cover platform-realm: view-realm, view-clients, query-clients, manage-clients"
    red "  - confirm KCADM_CLIENT_SECRET matches current Credentials secret in the UI"
    exit 1
}

client_internal_id() {
    local cid="$1"
    kcadm get clients -r "$REALM" -q "clientId=$cid" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true
}

green "==> kcadm authenticate"
kcadm_auth

# Confirm platform_admin realm role exists (Phase 5 prerequisite).
if ! kcadm get "roles/platform_admin" -r "$REALM" >/dev/null 2>&1; then
    red "realm role 'platform_admin' missing in $REALM"
    red "  re-run infrastructure/keycloak/clients/openbao.sh first; it creates the role"
    exit 1
fi
green "    platform_admin realm role present"

# ─── grafana client representation ────────────────────────────────────
# - confidential client-secret auth (not client-jwt — local-edition
#   simplification; private_key_jwt rotation is Phase 7d's housekeeping)
# - default scopes include `roles` so realm_access.roles is in tokens;
#   chart's grafana.ini role_attribute_path reads it for Admin mapping
# - PKCE S256 enforced for the auth-code flow
# - DPoP-binding OFF (Grafana doesn't support DPoP)
green "==> ensure $CLIENT_ID client in $REALM realm"

CLIENT_JSON=$(cat <<'EOF'
{
  "clientId": "grafana",
  "name": "Grafana",
  "description": "OIDC federation for Grafana platform-admin login (Phase 7.3)",
  "enabled": true,
  "protocol": "openid-connect",
  "rootUrl": "https://grafana.secforge.local",
  "baseUrl": "https://grafana.secforge.local",
  "redirectUris": [
    "https://grafana.secforge.local/login/generic_oauth"
  ],
  "webOrigins": ["https://grafana.secforge.local"],
  "publicClient": false,
  "bearerOnly": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": true,
  "fullScopeAllowed": false,
  "attributes": {
    "post.logout.redirect.uris": "https://grafana.secforge.local",
    "pkce.code.challenge.method": "S256",
    "use.refresh.tokens": "true",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "user.info.signed.response.alg": "RS256",
    "client_credentials.use_refresh_token": "false",
    "use.jwks.url": "false",
    "dpop.bound.access.tokens": "false"
  },
  "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
  "optionalClientScopes": ["offline_access", "address", "phone", "microprofile-jwt"]
}
EOF
)

kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c 'cat > /tmp/grafana-client.json' <<<"$CLIENT_JSON"

EXISTING=$(client_internal_id "$CLIENT_ID")
if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/grafana-client.json
    INTERNAL_ID="$EXISTING"
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/grafana-client.json
    INTERNAL_ID=$(client_internal_id "$CLIENT_ID")
fi

# ─── client_secret ────────────────────────────────────────────────────
green "==> client_secret"
SECRET_JSON=$(kcadm get "clients/$INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null || true)
SECRET=$(jq -r '.value // empty' <<<"$SECRET_JSON")
if [ -z "$SECRET" ]; then
    yellow "    no secret yet — regenerating"
    SECRET_JSON=$(kcadm create "clients/$INTERNAL_ID/client-secret" -r "$REALM" -i 2>&1 | tail -1)
    SECRET=$(jq -r '.value // empty' <<<"$SECRET_JSON")
fi

yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " grafana OIDC client_secret (capture now — printed once):"
yellow ""
yellow "   $SECRET"
yellow ""
yellow " Stage into OpenBao for the Helm values reference:"
yellow ""
yellow "   bao kv put secret/grafana/oidc client_secret='$SECRET'"
yellow ""
yellow " Then deploy kube-prometheus-stack:"
yellow ""
yellow "   bash infrastructure/observability/apply.sh"
yellow "═════════════════════════════════════════════════════════════════════"
