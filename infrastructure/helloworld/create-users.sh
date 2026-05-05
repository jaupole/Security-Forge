#!/usr/bin/env bash
# Phase 9.2 — create the four Hello World demo users in `secforge-tenants`.
#
# Users created:
#   jason     — test persona (distinct from jason.upole admin); document
#               owner; can view + edit
#   alice     — viewer; can view, cannot edit
#   bob       — no relationships; cannot view
#   test-bot  — present-but-empty automation account; TOTP enrolled on
#               first login. Used during 9.10 if a scripted login flow
#               proves easier than capturing a session from a real user.
#
# Required actions per user (per ADR-0007: TOTP + recovery codes; passkey
# ceremony returns at production hardening):
#   jason / alice / bob:
#     UPDATE_PASSWORD, CONFIGURE_TOTP, CONFIGURE_RECOVERY_AUTHN_CODES
#   test-bot:
#     CONFIGURE_TOTP, CONFIGURE_RECOVERY_AUTHN_CODES
#       (no UPDATE_PASSWORD — test-bot's password stays as the value
#        printed by this script so it can be replayed in scripted tests)
#
# Idempotent: re-running reconciles existing users to the desired shape.
# Temp passwords are regenerated on every run (operator captures fresh
# values from STDOUT).
#
# Auth (per ADR-0022): set BAO_TOKEN to an OpenBao token with read on
# secret/data/keycloak/clients/kcadm-admin.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/helloworld/create-users.sh
#
# Teardown of these users happens in infrastructure/helloworld/teardown.sh
# (Phase 9.12). DO NOT delete jason.upole — that is the operator's
# admin user, not a demo persona.

set -euo pipefail

# shellcheck source=../keycloak/_lib/kcadm-auth.sh
. "$(dirname "$0")/../keycloak/_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
REALM=secforge-tenants

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

# Helper: ensure user exists with the requested shape; echo USER_ID to stdout.
# Args: $1=username  $2=email  $3=firstName  $4=lastName  $5=requiredActions JSON array
ensure_user() {
    local username="$1" email="$2" first="$3" last="$4" req_actions="$5"
    local user_id
    user_id=$(kcadm get users -r "$REALM" -q "username=$username" --fields id 2>/dev/null \
        | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
    if [ -n "$user_id" ] && [ "$user_id" != "[]" ]; then
        green "    reconciling $username (id=$user_id)" >&2
        kcadm update users/"$user_id" -r "$REALM" \
            -s "email=$email" \
            -s "emailVerified=true" \
            -s "firstName=$first" \
            -s "lastName=$last" \
            -s 'enabled=true' \
            -s "requiredActions=$req_actions" >/dev/null
    else
        green "    creating $username" >&2
        user_id=$(kcadm create users -r "$REALM" \
            -s "username=$username" \
            -s "email=$email" \
            -s "emailVerified=true" \
            -s "firstName=$first" \
            -s "lastName=$last" \
            -s 'enabled=true' \
            -s "requiredActions=$req_actions" \
            -i 2>&1 | tr -d '\r\n')
    fi
    printf '%s' "$user_id"
}

DEMO_REQ='["UPDATE_PASSWORD","CONFIGURE_TOTP","CONFIGURE_RECOVERY_AUTHN_CODES"]'
BOT_REQ='["CONFIGURE_TOTP","CONFIGURE_RECOVERY_AUTHN_CODES"]'

declare -A TMP_PW

green "==> ensure user: jason (owner)"
JASON_ID=$(ensure_user jason jason@example.com Jason Demo "$DEMO_REQ")
TMP_PW[jason]="ChangeMe-jason-$(date +%s)-$RANDOM"
kcadm set-password -r "$REALM" --userid "$JASON_ID" --new-password "${TMP_PW[jason]}" --temporary

green "==> ensure user: alice (viewer)"
ALICE_ID=$(ensure_user alice alice@example.com Alice Demo "$DEMO_REQ")
TMP_PW[alice]="ChangeMe-alice-$(date +%s)-$RANDOM"
kcadm set-password -r "$REALM" --userid "$ALICE_ID" --new-password "${TMP_PW[alice]}" --temporary

green "==> ensure user: bob (no access)"
BOB_ID=$(ensure_user bob bob@example.com Bob Demo "$DEMO_REQ")
TMP_PW[bob]="ChangeMe-bob-$(date +%s)-$RANDOM"
kcadm set-password -r "$REALM" --userid "$BOB_ID" --new-password "${TMP_PW[bob]}" --temporary

green "==> ensure user: test-bot (automation; non-temporary password)"
BOT_ID=$(ensure_user test-bot test-bot@example.com Test Bot "$BOT_REQ")
TMP_PW[test-bot]="TestBot-$(date +%s)-$RANDOM"
kcadm set-password -r "$REALM" --userid "$BOT_ID" --new-password "${TMP_PW[test-bot]}"

green ""
green "Phase 9.2 users ready in realm '$REALM':"
green ""
printf '%-12s %-26s %-40s\n' "USERNAME" "EMAIL" "TEMP PASSWORD"
printf '%-12s %-26s %-40s\n' "--------" "-----" "-------------"
for u in jason alice bob test-bot; do
    case "$u" in
        jason)    email="jason@example.com" ;;
        alice)    email="alice@example.com" ;;
        bob)      email="bob@example.com" ;;
        test-bot) email="test-bot@example.com" ;;
    esac
    printf '%-12s %-26s %-40s\n' "$u" "$email" "${TMP_PW[$u]}"
done

yellow ""
yellow "On first login (via the BFF /login flow at https://app.secforge.local/login):"
yellow "  1. Enter username + temp password from the table above"
yellow "  2. Keycloak prompts for a new password (skip for test-bot)"
yellow "  3. Keycloak shows a QR code — scan with Okta Verify"
yellow "     (use distinct labels: 'SecForge demo - <username>')"
yellow "  4. Save the recovery codes shown — they survive a TOTP-app loss"
yellow "  5. Click Continue — Keycloak redirects back to the BFF"
yellow ""
yellow "Capture the temp passwords above NOW — they are not stored anywhere."
