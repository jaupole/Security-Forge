#!/usr/bin/env bash
# Phase 9.7 follow-up — register the `helloworld-api` client scope in
# Keycloak so the BFF's audience-at-login refresh (per ADR-0014) succeeds.
#
# Without this the apps/lib/api-auth.Client.MintTokenForAudience call
# fails: Keycloak rejects the refresh with
#   `error="invalid_request", reason="Invalid scopes: ... helloworld-api"`
# and the BFF returns 401 → frontend redirect-loops on /login.
#
# What this creates (idempotent):
#   1. Realm-level Client Scope `helloworld-api` (protocol=openid-connect)
#      with a hardcoded-audience mapper that injects `helloworld-api` into
#      the access token's `aud` claim only.
#   2. Adds the scope as an OPTIONAL client scope on the `helloworld-bff`
#      client (so it's only included when the BFF asks for it via the
#      `scope=helloworld-api` parameter on refresh — Q2/Q3 from ADR-0014).
#
# Phase 9.12 teardown removes both the scope and the client mapping.
#
# Auth: BAO_TOKEN with read on secret/data/keycloak/clients/kcadm-admin.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set.\n" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../keycloak/_lib/kcadm-auth.sh
. "$HERE/../keycloak/_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
REALM=secforge-tenants
SCOPE_NAME=helloworld-api

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- /opt/keycloak/bin/kcadm.sh "$@"
}

green "==> auth as kcadm-admin"
kcadm_admin_auth || exit 1

# 1. Create the client scope (or reconcile if it exists).
green "==> ensure client scope: $SCOPE_NAME"
SCOPE_ID=$(kcadm get client-scopes -r "$REALM" --query "name=$SCOPE_NAME" --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -z "$SCOPE_ID" ] || [ "$SCOPE_ID" = "[]" ]; then
    green "    creating $SCOPE_NAME"
    SCOPE_ID=$(kcadm create client-scopes -r "$REALM" \
        -s "name=$SCOPE_NAME" \
        -s 'protocol=openid-connect' \
        -s 'description=Adds helloworld-api audience to access tokens (Phase 9 demo)' \
        -s 'attributes."include.in.token.scope"=true' \
        -s 'attributes."display.on.consent.screen"=false' \
        -i 2>&1 | tr -d '\r\n')
    green "    created (id=$SCOPE_ID)"
else
    green "    already exists (id=$SCOPE_ID)"
fi

# 2. Add the audience-mapper to the scope (idempotent — name is unique).
green "==> ensure audience mapper on $SCOPE_NAME"
MAPPER_NAME="audience-helloworld-api"
EXISTING=$(kcadm get "client-scopes/$SCOPE_ID/protocol-mappers/models" -r "$REALM" 2>&1 \
    | grep -oE '"name":"[^"]+"' | grep -c "\"$MAPPER_NAME\"" || true)
if [ "$EXISTING" -eq 0 ]; then
    green "    creating $MAPPER_NAME"
    kcadm create "client-scopes/$SCOPE_ID/protocol-mappers/models" -r "$REALM" \
        -s "name=$MAPPER_NAME" \
        -s "protocol=openid-connect" \
        -s "protocolMapper=oidc-audience-mapper" \
        -s 'config."included.custom.audience"=helloworld-api' \
        -s 'config."id.token.claim"=false' \
        -s 'config."access.token.claim"=true' \
        -s 'config."introspection.token.claim"=false' \
        -s 'config."lightweight.claim"=false' \
        2>&1 | tail -1
else
    green "    mapper already present"
fi

# 3. Add the scope to the helloworld-bff client as OPTIONAL.
green "==> bind scope to client helloworld-bff (optional)"
CLIENT_ID=$(kcadm get clients -r "$REALM" -q clientId=helloworld-bff --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "[]" ]; then
    red "helloworld-bff client not found in $REALM"
    exit 1
fi

# kcadm requires PUT for client-scope binding; the endpoint is
# clients/<id>/optional-client-scopes/<scope-id>. Idempotent (PUT).
kubectl exec -n "$NS" "$POD" -c keycloak -- /opt/keycloak/bin/kcadm.sh \
    update "clients/$CLIENT_ID/optional-client-scopes/$SCOPE_ID" -r "$REALM" \
    -s '{}' --no-config 2>&1 | tail -1 || true

# Verification — fetch the client's optional scopes.
green "==> verify"
kcadm get "clients/$CLIENT_ID/optional-client-scopes" -r "$REALM" 2>&1 \
    | grep -E '"name"' | grep "$SCOPE_NAME" | head -1 \
    && green "    $SCOPE_NAME is in helloworld-bff's optional-client-scopes" \
    || red "    $SCOPE_NAME NOT in optional-client-scopes (manual fix needed)"
