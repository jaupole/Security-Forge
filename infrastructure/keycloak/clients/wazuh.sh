#!/usr/bin/env bash
# Phase 7d Item 7 — Idempotent provisioner for the Wazuh dashboard
# OIDC client in Keycloak's `platform` realm. Mirrors grafana.sh
# semantically but uses the post-ADR-0022 kcadm-admin pattern (sources
# _lib/kcadm-auth.sh) instead of the throwaway-client pattern.
#
# What this creates / ensures (idempotent):
#   - Client `wazuh-dashboard` in `platform` realm (confidential,
#     client-secret, standard auth-code flow + PKCE-S256, redirect to
#     https://wazuh.secforge.local/auth/openid/login).
#   - Realm role `platform_admin` is assumed to already exist (created
#     in Phase 5 by openbao.sh). If missing, this script aborts.
#   - Stores the client_secret in OpenBao at
#     secret/data/wazuh/oidc (keys: client_id, client_secret, issuer,
#     redirect_uri) so VSO can render it into a K8s Secret in wazuh ns.
#
# Auth (per ADR-0022): set BAO_TOKEN to a token with
#   - read on secret/data/keycloak/clients/kcadm-admin
#     (so kcadm-auth.sh can fetch kcadm-admin's client_secret)
#   - create+update on secret/data/wazuh/oidc
#     (so this script can persist the rendered Wazuh client_secret)
#
# OpenSearch Security plugin config (config.yml authc OIDC domain) +
# dashboard-side OIDC enablement (opensearch_dashboards.yml) live in
# the chart patches; see infrastructure/wazuh/vendor/PATCHES.md P-003.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/clients/wazuh.sh

set -euo pipefail

# shellcheck source=../_lib/kcadm-auth.sh
. "$(dirname "$0")/../_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
BAO_NS=openbao
BAO_POD=openbao-0
REALM=platform
CLIENT_ID=wazuh-dashboard
DASHBOARD_URL="https://wazuh.secforge.local"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN env required (see ADR-0022)"; exit 1; }

green "==> kcadm-admin authenticate"
kcadm_admin_auth || exit 1

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

client_internal_id() {
    kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true
}

# Confirm platform_admin realm role exists (Phase 5 prerequisite).
if ! kcadm get "roles/platform_admin" -r "$REALM" >/dev/null 2>&1; then
    red "realm role 'platform_admin' missing in $REALM"
    red "  re-run infrastructure/keycloak/clients/openbao.sh first; it creates the role"
    exit 1
fi
green "    platform_admin realm role present"

# ─── wazuh-dashboard client representation ────────────────────────────
# - confidential client-secret auth (matches grafana — chart-shaped
#   consumer with no native private_key_jwt support)
# - default scopes include `roles` so realm_access.roles ships in
#   tokens; OpenSearch Security plugin's roles_key reads from there
# - PKCE S256 enforced for the auth-code flow
# - DPoP OFF (OpenSearch Security plugin doesn't support DPoP-bound
#   tokens; same trade-off as grafana)
# - frontchannelLogout ON so dashboard logout clears the Keycloak SSO
#   session
green "==> ensure $CLIENT_ID client in $REALM realm"

CLIENT_JSON=$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "name": "Wazuh Dashboard",
  "description": "OIDC federation for the Wazuh OpenSearch Dashboards login (Phase 7d Item 7)",
  "enabled": true,
  "protocol": "openid-connect",
  "rootUrl": "${DASHBOARD_URL}",
  "baseUrl": "${DASHBOARD_URL}",
  "redirectUris": [
    "${DASHBOARD_URL}/auth/openid/login"
  ],
  "webOrigins": ["${DASHBOARD_URL}"],
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
    "post.logout.redirect.uris": "${DASHBOARD_URL}",
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
    sh -c 'cat > /tmp/wazuh-client.json' <<<"$CLIENT_JSON"

EXISTING=$(client_internal_id)
if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/wazuh-client.json >/dev/null
    INTERNAL_ID="$EXISTING"
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/wazuh-client.json >/dev/null
    INTERNAL_ID=$(client_internal_id)
fi
kubectl exec -n "$NS" "$POD" -c keycloak -- rm -f /tmp/wazuh-client.json >/dev/null 2>&1 || true

# ─── client_secret ────────────────────────────────────────────────────
green "==> client_secret"
SECRET_JSON=$(kcadm get "clients/$INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null | tr -d '\r' || true)
SECRET=$(printf '%s' "$SECRET_JSON" | jq -r '.value // empty')
if [ -z "$SECRET" ]; then
    yellow "    no secret yet — regenerating"
    SECRET_JSON=$(kcadm create "clients/$INTERNAL_ID/client-secret" -r "$REALM" -i 2>&1 | tr -d '\r' | tail -1)
    SECRET=$(printf '%s' "$SECRET_JSON" | jq -r '.value // empty')
fi
[ -z "$SECRET" ] && { red "    failed to obtain client_secret"; exit 1; }

# ─── persist to OpenBao for VSO consumption ───────────────────────────
green "==> persist OIDC client config to secret/data/wazuh/oidc"

ISSUER="https://auth.secforge.local/realms/${REALM}"
KV_JSON=$(jq -cn \
    --arg cid "$CLIENT_ID" \
    --arg cs "$SECRET" \
    --arg iss "$ISSUER" \
    --arg ru "${DASHBOARD_URL}/auth/openid/login" \
    '{client_id:$cid, client_secret:$cs, issuer:$iss, redirect_uri:$ru, source:"phase-7d-item-7"}')

KV_PATH=/tmp/wazuh-oidc-$$.json
kubectl exec -i -n "$BAO_NS" "$BAO_POD" -c openbao -- \
    sh -c "umask 077; cat > $KV_PATH" <<<"$KV_JSON"

if ! kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao kv put -mount=secret "wazuh/oidc" "@${KV_PATH}" >/dev/null 2>&1; then
    kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_PATH" >/dev/null 2>&1 || true
    red "    bao kv put failed at secret/data/wazuh/oidc"
    exit 1
fi
kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_PATH" >/dev/null 2>&1 || true

unset SECRET KV_JSON

green ""
green "Phase 7d Item 7 — wazuh-dashboard OIDC client provisioned."
green ""
green "Client config written to:"
green "  secret/data/wazuh/oidc"
green "  Fields: client_id, client_secret, issuer, redirect_uri"
green ""
green "Next:"
green "  1. Add wazuh-vso K8s auth role + extend vso policy:"
green "       infrastructure/openbao/policies/vso.hcl  (add secret/data/wazuh/oidc paths)"
green "       infrastructure/vault-secrets-operator/configure-openbao-role.sh  (add wazuh-vso)"
green "  2. VSO binding for wazuh ns:"
green "       infrastructure/wazuh/vso-binding.yaml  (renders K8s Secret wazuh-oidc)"
green "  3. Apply chart patch P-003 to opt the dashboard into OIDC."
green "  4. Apply security-plugin config.yml + roles_mapping.yml updates."
green ""
green "Verify the client end-to-end after applying P-003 + security config:"
green "  Browse to https://wazuh.secforge.local/ — should redirect to Keycloak;"
green "  log in as a user with 'platform_admin' realm role; should land on the"
green "  dashboard with all_access privileges."
green ""
