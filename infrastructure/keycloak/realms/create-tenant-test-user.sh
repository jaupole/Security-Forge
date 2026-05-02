#!/usr/bin/env bash
# Phase 6.9 — create a tenant-realm test user for the BFF login flow.
#
# Why: the helloworld-bff client lives in `secforge-tenants` (the
# customer-facing realm), but Phase 3 only enrolled jaupole (master
# realm admin) and jason.upole (platform realm user). The first
# end-to-end BFF login needs a user in secforge-tenants.
#
# What this creates / ensures (idempotent):
#   - User `jason.upole` in `secforge-tenants` realm
#   - Email: jaupole@googlemail.com (matches Phase 3 jaupole's email)
#   - Email verified: true (skip the verification gate)
#   - Required actions on first login: UPDATE_PASSWORD + CONFIGURE_TOTP
#       Keycloak will walk the user through both during the BFF flow.
#   - Temporary password (printed to STDOUT once; capture and use for
#       the first BFF login).
#
# Auth (per ADR-0022): set BAO_TOKEN to an OpenBao token with read on
# secret/data/keycloak/clients/kcadm-admin.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/realms/create-tenant-test-user.sh

set -euo pipefail

# shellcheck source=../_lib/kcadm-auth.sh
. "$(dirname "$0")/../_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
REALM=secforge-tenants
USERNAME="jason.upole"
EMAIL="jaupole@googlemail.com"
FIRST_NAME="Jason"
LAST_NAME="Upole"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# Authenticate as kcadm-admin (per ADR-0022).
green "==> kcadm config credentials --client kcadm-admin (master realm)"
kcadm_admin_auth || exit 1
green "    auth ok"

# Find or create the user.
USER_ID=$(kcadm get users -r "$REALM" -q "username=$USERNAME" --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -n "$USER_ID" ] && [ "$USER_ID" != "[]" ]; then
    green "==> user $USERNAME exists in $REALM (id=$USER_ID); reconciling"
    kcadm update users/"$USER_ID" -r "$REALM" \
        -s "email=$EMAIL" \
        -s "emailVerified=true" \
        -s "firstName=$FIRST_NAME" \
        -s "lastName=$LAST_NAME" \
        -s 'enabled=true' \
        -s "requiredActions=[\"UPDATE_PASSWORD\",\"CONFIGURE_TOTP\"]"
else
    green "==> creating user $USERNAME in realm $REALM"
    USER_ID=$(kcadm create users -r "$REALM" \
        -s "username=$USERNAME" \
        -s "email=$EMAIL" \
        -s "emailVerified=true" \
        -s "firstName=$FIRST_NAME" \
        -s "lastName=$LAST_NAME" \
        -s 'enabled=true' \
        -s "requiredActions=[\"UPDATE_PASSWORD\",\"CONFIGURE_TOTP\"]" \
        -i 2>&1 | tr -d '\r\n')
    green "    created (id=$USER_ID)"
fi

# Set a temporary password — Keycloak will require user to change it.
TMP_PW="ChangeMe-$(date +%s)"
green "==> set temporary password (must change on first login)"
kcadm set-password -r "$REALM" --userid "$USER_ID" \
    --new-password "$TMP_PW" --temporary

green ""
green "User ready in realm '$REALM':"
green "  username:  $USERNAME"
green "  password:  $TMP_PW"
yellow ""
yellow "On first login (via the BFF /login flow):"
yellow "  1. Enter username + the temp password above"
yellow "  2. Keycloak prompts you to set a new password"
yellow "  3. Keycloak shows a QR code for TOTP — scan with your authenticator app"
yellow "     (use a different label than your platform-realm jason.upole — e.g."
yellow "      'SecForge tenants - jason.upole')"
yellow "  4. Save the recovery codes Keycloak shows"
yellow "  5. Click Continue — Keycloak redirects to BFF /auth/callback"
yellow ""
green "Capture the temp password now — it won't be shown again."
