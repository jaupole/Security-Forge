#!/usr/bin/env bash
# Phase 8a.4 — Idempotent provisioner for the Teleport OIDC client
# in Keycloak's `platform` realm + the three realm roles
# (`platform_admin`, `platform_developer`, `platform_viewer`)
# that Teleport's OIDCConnector maps to viewer/developer/admin
# Teleport roles.
#
# Mirrors the post-ADR-0022 pattern from
# infrastructure/keycloak/clients/wazuh.sh (sources _lib/kcadm-auth.sh
# for kcadm-admin auth). Persists the client_secret + issuer +
# redirect_uri to OpenBao at secret/data/teleport/oidc so VSO can
# render it into a K8s Secret in `teleport` ns (8b's chart values
# reference that Secret via secretKeyRef).
#
# Auth: BAO_TOKEN with read on secret/data/keycloak/clients/kcadm-admin
# and create+update on secret/data/teleport/oidc.
#
# Realm role naming:
#   - platform_admin     → Teleport `admin` (full kubectl + DBs;
#                          requires hardware FIDO2 per Teleport
#                          per-session MFA setting).
#   - platform_developer → Teleport `developer` (namespace-scoped
#                          write + DB read; configured in 8b).
#   - platform_viewer    → Teleport `viewer` (read-only; configured
#                          in 8b).
#
# Usage:
#   BAO_TOKEN=hvs.xxx bash infrastructure/keycloak/clients/teleport.sh

set -euo pipefail

# shellcheck source=../_lib/kcadm-auth.sh
. "$(dirname "$0")/../_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
BAO_NS=openbao
BAO_POD=openbao-0
REALM=platform
CLIENT_ID=teleport
TELEPORT_URL="https://tp.secforge.local"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN env required"; exit 1; }

green "==> kcadm-admin authenticate"
kcadm_admin_auth || exit 1

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# ─── 1. Realm roles ────────────────────────────────────────────────────
green "==> ensure platform_{admin,developer,viewer} realm roles in $REALM"
for role in platform_admin platform_developer platform_viewer; do
    if kcadm get "roles/$role" -r "$REALM" >/dev/null 2>&1; then
        yellow "    $role: exists"
    else
        kcadm create roles -r "$REALM" -s "name=$role" \
            -s "description=Phase 8 — maps to Teleport role" >/dev/null
        green "    $role: created"
    fi
done

# ─── 2. teleport client ────────────────────────────────────────────────
client_internal_id() {
    kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true
}

green "==> ensure $CLIENT_ID client in $REALM realm"

# Confidential client-secret auth + PKCE-S256. Teleport's OIDCConnector
# uses the standard auth-code flow; DPoP is not in Teleport's path.
# defaultClientScopes includes `roles` so realm_access.roles ships in
# tokens — that's the claim Teleport's claims_to_roles maps from.
CLIENT_JSON=$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "name": "Teleport",
  "description": "OIDC federation for the Teleport access broker (Phase 8).",
  "enabled": true,
  "protocol": "openid-connect",
  "rootUrl": "${TELEPORT_URL}",
  "baseUrl": "${TELEPORT_URL}",
  "redirectUris": [
    "${TELEPORT_URL}/v1/webapi/oidc/callback"
  ],
  "webOrigins": ["${TELEPORT_URL}"],
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
    "post.logout.redirect.uris": "${TELEPORT_URL}",
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
    sh -c 'cat > /tmp/teleport-client.json' <<<"$CLIENT_JSON"

EXISTING=$(client_internal_id)
if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/teleport-client.json >/dev/null
    INTERNAL_ID="$EXISTING"
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/teleport-client.json >/dev/null
    INTERNAL_ID=$(client_internal_id)
fi
kubectl exec -n "$NS" "$POD" -c keycloak -- rm -f /tmp/teleport-client.json >/dev/null 2>&1 || true

# ─── 3. client_secret ──────────────────────────────────────────────────
green "==> client_secret"
SECRET_JSON=$(kcadm get "clients/$INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null | tr -d '\r' || true)
SECRET=$(printf '%s' "$SECRET_JSON" | jq -r '.value // empty')
if [ -z "$SECRET" ]; then
    yellow "    no secret yet — regenerating"
    SECRET_JSON=$(kcadm create "clients/$INTERNAL_ID/client-secret" -r "$REALM" -i 2>&1 | tr -d '\r' | tail -1)
    SECRET=$(printf '%s' "$SECRET_JSON" | jq -r '.value // empty')
fi
[ -z "$SECRET" ] && { red "    failed to obtain client_secret"; exit 1; }

# ─── 4. Persist to OpenBao ────────────────────────────────────────────
green "==> persist OIDC client config to secret/data/teleport/oidc"

ISSUER="https://auth.secforge.local/realms/${REALM}"
KV_JSON=$(jq -cn \
    --arg cid "$CLIENT_ID" \
    --arg cs "$SECRET" \
    --arg iss "$ISSUER" \
    --arg ru "${TELEPORT_URL}/v1/webapi/oidc/callback" \
    '{client_id:$cid, client_secret:$cs, issuer:$iss, redirect_uri:$ru, source:"phase-8a"}')

KV_PATH=/tmp/teleport-oidc-$$.json
kubectl exec -i -n "$BAO_NS" "$BAO_POD" -c openbao -- \
    sh -c "umask 077; cat > $KV_PATH" <<<"$KV_JSON"

if ! kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao kv put -mount=secret "teleport/oidc" "@${KV_PATH}" >/dev/null 2>&1; then
    kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_PATH" >/dev/null 2>&1 || true
    red "    bao kv put failed at secret/data/teleport/oidc"
    exit 1
fi
kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_PATH" >/dev/null 2>&1 || true

unset SECRET KV_JSON

green ""
green "Phase 8a.4 — Teleport Keycloak client + 3 realm roles provisioned."
green ""
green "Realm roles ready (assign to humans in Phase 8b smoke test):"
green "  platform_admin     → Teleport admin     (hardware FIDO2 required)"
green "  platform_developer → Teleport developer"
green "  platform_viewer    → Teleport viewer"
green ""
green "Client config written to:"
green "  secret/data/teleport/oidc"
green "  Fields: client_id, client_secret, issuer, redirect_uri"
green ""
green "VSO will render the K8s Secret teleport/teleport-oidc-vso once"
green "the binding (01-vso-binding.yaml) is applied."
green ""
