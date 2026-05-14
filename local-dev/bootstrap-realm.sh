#!/usr/bin/env bash
# bootstrap-realm.sh — one-shot create the secforge-tenants realm,
# Organizations support, and the two ecosystem clients (portal +
# control) inside the local Keycloak dev container.
#
# Re-run-safe: existing realm/client returns 409 from kcadm; we
# treat that as "already there" and continue.
#
# Pre-condition: docker-compose.dev.yml is up and healthy.
#
# After this script:
#   - Realm `secforge-tenants` exists with Organizations enabled
#   - Public client `ecosystem-portal` exists (used by the portal SPA)
#   - Confidential client `ecosystem-control` exists (used by the
#     control-plane API for Admin REST calls)
#   - The control client's secret is printed to stdout — paste into
#     your Ecosystem Control .env file as KEYCLOAK_ADMIN_CLIENT_SECRET.

set -euo pipefail

KC_CONTAINER=secforge-keycloak-dev
REALM=secforge-tenants
PORTAL_CLIENT_ID=ecosystem-portal
CONTROL_CLIENT_ID=ecosystem-control

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! docker ps --format '{{.Names}}' | grep -q "^$KC_CONTAINER$"; then
  red "Keycloak container '$KC_CONTAINER' is not running."
  red "Start it with: docker compose -f local-dev/docker-compose.dev.yml up -d"
  exit 1
fi

# Helper: run kcadm in the container with admin credentials cached.
kc() { docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"; }

green "==> authenticate kcadm"
kc config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password admin >/dev/null

green "==> create realm $REALM (Organizations enabled)"
if kc get realms/$REALM >/dev/null 2>&1; then
  yellow "    realm $REALM already exists — skipping create"
else
  kc create realms -s realm=$REALM -s enabled=true \
    -s organizationsEnabled=true \
    -s 'displayName=SecForge Tenants' \
    -s loginWithEmailAllowed=true \
    -s registrationAllowed=true >/dev/null
  green "    created"
fi

# Direct access grants on the portal client are LOCAL-DEV ONLY. They
# enable the password grant flow used by `pnpm cli dev:get-token` so we
# can mint test-user tokens without a browser. The production realm
# config MUST set this to false (browser PKCE is the only legitimate
# user flow). See `feedback_local_dev_no_mfa.md`-class reasoning.
green "==> create public client $PORTAL_CLIENT_ID"
if kc get clients -r $REALM -q clientId=$PORTAL_CLIENT_ID --fields id 2>/dev/null | grep -q '"id"'; then
  yellow "    client $PORTAL_CLIENT_ID already exists — skipping create"
else
  kc create clients -r $REALM \
    -s clientId=$PORTAL_CLIENT_ID \
    -s name='Ecosystem Portal' \
    -s 'description=Custom landing + admin UI; end-users authenticate here' \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s 'redirectUris=["http://portal.localhost:5173/*","http://portal.localhost/*"]' \
    -s 'webOrigins=["http://portal.localhost:5173","http://portal.localhost"]' >/dev/null
  green "    created"
fi

green "==> create confidential client $CONTROL_CLIENT_ID"
if kc get clients -r $REALM -q clientId=$CONTROL_CLIENT_ID --fields id 2>/dev/null | grep -q '"id"'; then
  yellow "    client $CONTROL_CLIENT_ID already exists — skipping create"
  CONTROL_INTERNAL_ID=$(kc get clients -r $REALM -q clientId=$CONTROL_CLIENT_ID --fields id | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)
else
  kc create clients -r $REALM \
    -s clientId=$CONTROL_CLIENT_ID \
    -s name='Ecosystem Control' \
    -s 'description=Service account used by the control-plane API to call Keycloak Admin' \
    -s enabled=true \
    -s publicClient=false \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false >/dev/null
  green "    created"
  CONTROL_INTERNAL_ID=$(kc get clients -r $REALM -q clientId=$CONTROL_CLIENT_ID --fields id | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)

  # Grant the service account the realm-management roles needed for
  # Organizations + user CRUD. (manage-users, manage-realm,
  # query-users, view-users — minimum for portal flows.)
  SA_USER_ID=$(kc get clients/$CONTROL_INTERNAL_ID/service-account-user -r $REALM --fields id | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)
  REALM_MGMT_CLIENT_ID=$(kc get clients -r $REALM -q clientId=realm-management --fields id | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)
  for ROLE in manage-users query-users view-users manage-realm; do
    kc add-roles -r $REALM \
      --uid $SA_USER_ID \
      --cclientid realm-management --rolename $ROLE >/dev/null 2>&1 || true
  done
  green "    granted realm-management roles to ecosystem-control service account"
fi

# Audience self-mappers — required for token verification on the
# control-plane API. Without these, tokens minted for these clients
# carry only the default `account` audience, which the API would have
# to either trust (insecure) or reject (everything 401s). See
# `docs/06-reference/api-security-status.md` Tier 1.
green "==> add audience self-mappers"
for CLIENT in $PORTAL_CLIENT_ID $CONTROL_CLIENT_ID; do
  CLIENT_INTERNAL_ID=$(kc get clients -r $REALM -q clientId=$CLIENT --fields id | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)
  if kc get clients/$CLIENT_INTERNAL_ID/protocol-mappers/models -r $REALM 2>/dev/null | grep -q '"name" : "audience-self"'; then
    yellow "    $CLIENT audience-self mapper already present"
  else
    kc create clients/$CLIENT_INTERNAL_ID/protocol-mappers/models -r $REALM \
      -s name=audience-self \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=$CLIENT" \
      -s 'config."id.token.claim"=false' \
      -s 'config."access.token.claim"=true' >/dev/null
    green "    added audience-self mapper to $CLIENT"
  fi
done

green "==> read $CONTROL_CLIENT_ID secret"
SECRET=$(kc get clients/$CONTROL_INTERNAL_ID/client-secret -r $REALM | sed -n 's/.*"value" : "\([^"]*\)".*/\1/p' | head -1)
echo
green "✓ Bootstrap complete."
cat <<EOF

  Realm:          $REALM
  Portal client:  $PORTAL_CLIENT_ID  (public, redirect: http://portal.localhost:5173/*)
  Control client: $CONTROL_CLIENT_ID  (confidential, service-account)

  Add to Ecosystem Control/.env:
    KEYCLOAK_URL=http://auth.localhost:8080
    KEYCLOAK_REALM=$REALM
    KEYCLOAK_ADMIN_CLIENT_ID=$CONTROL_CLIENT_ID
    KEYCLOAK_ADMIN_CLIENT_SECRET=$SECRET

  Add to your hosts file (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts):
    127.0.0.1  auth.localhost
    127.0.0.1  portal.localhost
    127.0.0.1  proposalapp.localhost
    127.0.0.1  managerapp.localhost

  Open http://auth.localhost:8080  →  admin/admin   (master realm)
  Open http://auth.localhost:8080/admin/master/console/#/$REALM  →  realm view

EOF
