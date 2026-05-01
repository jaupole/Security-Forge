#!/usr/bin/env bash
# Phase 6b-0 token-exchange spike — setup script.
#
# Idempotent provisioner for two throwaway clients in the
# `secforge-tenants` realm:
#
#   spike-bff   client-jwt (private_key_jwt PS256), serviceAccountsEnabled=true
#               so we can mint an initial subject token via client_credentials
#               without dragging the auth-code+browser flow into a 2h spike.
#               PAR/PKCE attributes are set for shape-fidelity but are inert
#               on the client_credentials grant. DPoP is intentionally OFF
#               for this client — generating DPoP proofs from a shell script
#               is non-trivial; the DPoP-binding question is answered
#               separately by reading Keycloak's behavior in 6b-1 against
#               the helloworld-bff (which already has DPoP turned on).
#
#   spike-api   bearer-only audience target. No flows enabled. Exists
#               solely so the realm has a clientId to use as `audience`
#               in the exchange request and so we have a target for the
#               fine-grained exchange permission.
#
# A per-spike RSA-2048 keypair lives at /tmp/secforge-spike/spike-bff-*.pem
# (intentionally outside the repo; tear-down nukes the directory).
#
# Fine-grained exchange permission: enable management permissions on
# spike-api, find the `token-exchange` scope-permission, attach a
# client-policy that allows spike-bff to invoke that scope.
#
# This script is committed for future reproduction, not retention.
# It does NOT delete the clients on its own — see `spike-token-exchange.sh tear-down`.

set -euo pipefail

NS=keycloak
POD=keycloak-0
REALM=secforge-tenants
BFF_CLIENT=spike-bff
API_CLIENT=spike-api
SPIKE_DIR=/tmp/secforge-spike
KEY_FILE="$SPIKE_DIR/spike-bff-private.pem"
PUB_FILE="$SPIKE_DIR/spike-bff-public.pem"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

usage() {
    cat <<EOF
Usage:
    KCADM_CLIENT_SECRET=... \\
        bash $(basename "$0") [up | tear-down]

Default action is 'up'.

Auth: kcadm authenticates as the 'kcadm-spike' service-account client in the
master realm via client_credentials. Keycloak 26.x kcadm has no --otp flag,
so user-with-TOTP auth is not viable; the kcadm-spike client (created
manually in the admin UI before running this script) holds the 6 scoped
client roles needed on secforge-tenants-realm.

The kcadm-spike client itself is NOT created or deleted by this script.
Tear-down removes spike-bff and spike-api in secforge-tenants; you delete
kcadm-spike from the master realm UI separately when the spike concludes.
EOF
}

ACTION="${1:-up}"
case "$ACTION" in
    up|tear-down) ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac

[ -z "${KCADM_CLIENT_SECRET:-}" ] && { red "env KCADM_CLIENT_SECRET is required"; exit 1; }

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# Authenticate kcadm as the kcadm-spike service-account client in master.
# --server localhost:8080 is the Keycloak listener inside the pod (kcadm
# runs in-pod via `kubectl exec`).
kcadm_auth() {
    if kcadm config credentials \
            --server http://localhost:8080 --realm master \
            --client kcadm-spike --secret "$KCADM_CLIENT_SECRET" \
            >/dev/null 2>&1; then
        green "    kcadm auth ok (client_credentials as kcadm-spike)"
        return
    fi
    red "kcadm auth failed as client kcadm-spike"
    red "  - confirm kcadm-spike client exists in master realm with"
    red "    Service accounts roles enabled and the 6 client roles assigned"
    red "    on secforge-tenants-realm (view-realm, view-clients, query-clients,"
    red "    manage-clients, view-authorization, manage-authorization)"
    red "  - confirm KCADM_CLIENT_SECRET matches the current Credentials secret"
    red "    (regenerating in the UI invalidates the old value)"
    exit 1
}

client_internal_id() {
    local cid="$1"
    kcadm get clients -r "$REALM" -q "clientId=$cid" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true
}

if [ "$ACTION" = "tear-down" ]; then
    green "==> tear-down: kcadm auth"
    kcadm_auth
    for cid in "$BFF_CLIENT" "$API_CLIENT"; do
        iid=$(client_internal_id "$cid")
        if [ -n "$iid" ]; then
            yellow "    deleting client $cid (id=$iid)"
            kcadm delete "clients/$iid" -r "$REALM" || true
        else
            yellow "    client $cid not found; skipping"
        fi
    done
    if [ -d "$SPIKE_DIR" ]; then
        yellow "    deleting $SPIKE_DIR"
        rm -rf "$SPIKE_DIR"
    fi
    green "tear-down complete"
    exit 0
fi

# ─── 1. Generate keypair (idempotent) ───────────────────────────────
green "==> spike-bff keypair"
mkdir -p "$SPIKE_DIR"
chmod 700 "$SPIKE_DIR"
if [ -f "$KEY_FILE" ] && [ -f "$PUB_FILE" ]; then
    yellow "    reusing $KEY_FILE"
else
    openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
    openssl rsa -in "$KEY_FILE" -pubout -out "$PUB_FILE" 2>/dev/null
    chmod 600 "$KEY_FILE"
    green "    generated"
fi
PUB_BODY=$(sed -e '/^-----BEGIN/d' -e '/^-----END/d' "$PUB_FILE" | tr -d '\n')

# ─── 2. Authenticate kcadm ──────────────────────────────────────────
green "==> kcadm authenticate"
kcadm_auth

# ─── 3. spike-api (audience target) ─────────────────────────────────
green "==> ensure $API_CLIENT in $REALM"
API_JSON=$(cat <<'EOF'
{
  "clientId": "spike-api",
  "name": "spike-api",
  "description": "Phase 6b-0 spike — audience target for token-exchange tests. No flows.",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "attributes": {
    "access.token.signed.response.alg": "RS256",
    "access.token.header.type.rfc9068": "true"
  }
}
EOF
)
kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c "cat > /tmp/spike-api.json" <<<"$API_JSON"
api_id=$(client_internal_id "$API_CLIENT")
if [ -n "$api_id" ]; then
    yellow "    exists (id=$api_id); updating"
    kcadm update "clients/$api_id" -r "$REALM" -f /tmp/spike-api.json
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/spike-api.json
    api_id=$(client_internal_id "$API_CLIENT")
fi

# ─── 4. spike-bff (BFF-shaped, client-jwt, client_credentials on) ───
green "==> ensure $BFF_CLIENT in $REALM"
BFF_JSON=$(cat <<EOF
{
  "clientId": "spike-bff",
  "name": "spike-bff",
  "description": "Phase 6b-0 spike — token-exchange initiator. private_key_jwt (PS256), client_credentials enabled. DPoP intentionally OFF in this client (see spike-token-exchange.sh comment).",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "bearerOnly": false,
  "clientAuthenticatorType": "client-jwt",
  "redirectUris": ["http://localhost:8080/callback"],
  "webOrigins": ["http://localhost:8080"],
  "rootUrl": "http://localhost:8080",
  "baseUrl": "http://localhost:8080",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "frontchannelLogout": true,
  "fullScopeAllowed": false,
  "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
  "optionalClientScopes": ["offline_access", "address", "phone", "microprofile-jwt"],
  "attributes": {
    "post.logout.redirect.uris": "http://localhost:8080",
    "use.refresh.tokens": "true",
    "client_credentials.use_refresh_token": "false",
    "dpop.bound.access.tokens": "false",
    "require.pushed.authorization.requests": "true",
    "pkce.code.challenge.method": "S256",
    "use.jwks.url": "false",
    "use.jwks.string": "false",
    "jwt.credential.public.key": "$PUB_BODY",
    "token.endpoint.auth.signing.alg": "PS256",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "access.token.lifespan": "300",
    "access.token.header.type.rfc9068": "true"
  }
}
EOF
)
kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c "cat > /tmp/spike-bff.json" <<<"$BFF_JSON"
bff_id=$(client_internal_id "$BFF_CLIENT")
if [ -n "$bff_id" ]; then
    yellow "    exists (id=$bff_id); updating"
    kcadm update "clients/$bff_id" -r "$REALM" -f /tmp/spike-bff.json
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/spike-bff.json
    bff_id=$(client_internal_id "$BFF_CLIENT")
fi

# ─── 5. Fine-grained exchange permission ────────────────────────────
# Enable management permissions on spike-api, then attach a client-policy
# that names spike-bff to the `token-exchange` scope-permission. Without
# this, every exchange returns invalid_target / access_denied.
green "==> fine-grained exchange permission (spike-bff → spike-api)"

# 5a. Enable management permissions on the target client.
kcadm update "clients/$api_id/management/permissions" -r "$REALM" \
    -s enabled=true >/dev/null
PERMS_JSON=$(kcadm get "clients/$api_id/management/permissions" -r "$REALM")
TOKEN_EXCHANGE_PERM_ID=$(jq -r '.scopePermissions["token-exchange"]' <<<"$PERMS_JSON")
if [ -z "$TOKEN_EXCHANGE_PERM_ID" ] || [ "$TOKEN_EXCHANGE_PERM_ID" = "null" ]; then
    red "    could not read scopePermissions['token-exchange']; permissions response was:"
    echo "$PERMS_JSON" >&2
    exit 1
fi
green "    token-exchange scope-permission id: $TOKEN_EXCHANGE_PERM_ID"

# 5b. Find the realm-management client (where authz policies live for
# the master/realm authz of management permissions).
RM_ID=$(client_internal_id "realm-management")
if [ -z "$RM_ID" ]; then
    red "    realm-management client not found in realm $REALM"
    exit 1
fi

# 5c. Create or reuse a client-policy named `spike-bff-may-exchange`
# that lists spike-bff among its allowed clients.
POLICY_NAME="spike-bff-may-exchange-for-spike-api"

# Look up an existing policy by name in realm-management's authz config.
EXISTING_POLICY=$(kcadm get "clients/$RM_ID/authz/resource-server/policy" -r "$REALM" \
    -q "name=$POLICY_NAME" --fields id,name --format csv --noquotes 2>/dev/null \
    | tr -d '\r' | awk -F, -v name="$POLICY_NAME" '$2==name {print $1; exit}' || true)

POLICY_BODY=$(cat <<EOF
{
  "type": "client",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "name": "$POLICY_NAME",
  "description": "Phase 6b-0 spike — allows spike-bff to exchange for aud=spike-api.",
  "clients": ["$BFF_CLIENT"]
}
EOF
)
kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c "cat > /tmp/spike-policy.json" <<<"$POLICY_BODY"

if [ -n "$EXISTING_POLICY" ]; then
    yellow "    policy exists (id=$EXISTING_POLICY); updating"
    kcadm update "clients/$RM_ID/authz/resource-server/policy/client/$EXISTING_POLICY" \
        -r "$REALM" -f /tmp/spike-policy.json
    POLICY_ID="$EXISTING_POLICY"
else
    green "    creating policy"
    kcadm create "clients/$RM_ID/authz/resource-server/policy/client" \
        -r "$REALM" -f /tmp/spike-policy.json
    POLICY_ID=$(kcadm get "clients/$RM_ID/authz/resource-server/policy" -r "$REALM" \
        -q "name=$POLICY_NAME" --fields id,name --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | awk -F, -v name="$POLICY_NAME" '$2==name {print $1; exit}')
fi
green "    policy id: $POLICY_ID"

# 5d. Attach the policy to the token-exchange scope-permission. The
# permission's `policies` field is an array of policy IDs. We have to
# preserve any existing policies; the API replaces the field on PUT.
PERM_BODY=$(kcadm get "clients/$RM_ID/authz/resource-server/permission/scope/$TOKEN_EXCHANGE_PERM_ID" \
    -r "$REALM")
NEW_PERM=$(jq --arg pid "$POLICY_ID" \
    '.policies = ((.policies // []) + [$pid] | unique)' <<<"$PERM_BODY")
kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
    sh -c "cat > /tmp/spike-perm.json" <<<"$NEW_PERM"
kcadm update "clients/$RM_ID/authz/resource-server/permission/scope/$TOKEN_EXCHANGE_PERM_ID" \
    -r "$REALM" -f /tmp/spike-perm.json
green "    permission policy list: $(jq -r '.policies | join(",")' <<<"$NEW_PERM")"

# ─── 6. Summary ─────────────────────────────────────────────────────
yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " spike-bff and spike-api ready in realm '$REALM'."
yellow ""
yellow "   spike-bff key:       $KEY_FILE"
yellow "   spike-bff client id: $bff_id"
yellow "   spike-api client id: $api_id"
yellow ""
yellow " Run end-to-end test:"
yellow "   bash infrastructure/keycloak/spike-token-exchange-test.sh"
yellow ""
yellow " Tear down (after spike):"
yellow "   KCADM_CLIENT_SECRET=... \\"
yellow "       bash infrastructure/keycloak/spike-token-exchange.sh tear-down"
yellow "   Then delete the kcadm-spike client manually in the master realm UI."
yellow "═════════════════════════════════════════════════════════════════════"
