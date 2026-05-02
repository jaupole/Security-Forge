#!/usr/bin/env bash
# kcadm-admin.sh — manages the kcadm-admin service-account client in
# Keycloak's master realm per ADR-0022.
#
# THIS SCRIPT DOES NOT BOOTSTRAP THE CLIENT. The very first creation is
# a one-time manual UI step by the operator (chicken-and-egg: the
# provisioning script needs kcadm-admin to authenticate, but the client
# does not yet exist). See § Bootstrap caveat in ADR-0022. After that
# bootstrap, this script:
#
#   1. Reads kcadm-admin's client_secret from OpenBao at
#      secret/data/keycloak/clients/kcadm-admin (KV-v2).
#   2. Authenticates kcadm as kcadm-admin via client_credentials.
#   3. Ensures every role from ADR-0022's "Roles granted" table is
#      applied to kcadm-admin's service-account user (idempotent —
#      kcadm add-roles is a no-op if the role is already granted).
#   4. Optionally rotates the client_secret (--rotate flag) and writes
#      the new value back into OpenBao at the same KV path.
#
# Required env:
#   BAO_TOKEN     OpenBao token with read (or read+write if --rotate)
#                 capability on secret/data/keycloak/clients/kcadm-admin.
#                 The operator runs `bao token create -policy=…` to mint
#                 this; ttl ≤ 5m is recommended.
#
# Optional flags:
#   --rotate      Rotate kcadm-admin's client_secret. Generates a fresh
#                 secret in Keycloak, writes it back to OpenBao, then
#                 reconciles the role grants under the new secret.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/clients/kcadm-admin.sh
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/clients/kcadm-admin.sh --rotate
#
# § Bootstrap caveat (manual UI steps for first creation, one-time):
#   1. Open https://auth-admin.secforge.local/admin/master/console/
#   2. Realm: master → Clients → Create client
#        Client ID: kcadm-admin
#        Client authentication: ON
#        Authorization: OFF
#        Standard flow: OFF
#        Direct access grants: OFF
#        Implicit flow: OFF
#        Service accounts roles: ON
#   3. Save → copy the generated Credentials → Client secret
#   4. Write to OpenBao (substitute the secret value):
#        kubectl exec -n openbao openbao-0 -c openbao -- \
#            env BAO_TOKEN=$ROOT_TOKEN \
#            bao kv put secret/keycloak/clients/kcadm-admin \
#                client_secret='THE-COPIED-SECRET-VALUE'
#   5. Run this script (without --rotate) to apply the role grants.

set -euo pipefail

NS_KC=keycloak
KC_POD=keycloak-0
NS_BAO=openbao
BAO_POD=openbao-0
KV_PATH="secret/keycloak/clients/kcadm-admin"
KCADM_CLIENT_ID=kcadm-admin

ROTATE=0
for arg in "$@"; do
    case "$arg" in
        --rotate) ROTATE=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN env var is required (see § Required env in script header)"; exit 1; }

# bao() runs the OpenBao CLI inside openbao-0 with BAO_TOKEN injected.
# Mirrors the wrapper pattern in infrastructure/openbao/configure-*.sh
# (the doubled `bao bao` is intentional: bash function `bao` + the binary
# `bao` inside the pod — see ADR-0022 § Host-side access path option (b)).
bao() {
    kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# kcadm() runs kcadm.sh inside keycloak-0. Caller is responsible for
# having run `kcadm config credentials` first.
kcadm() {
    kubectl exec -n "$NS_KC" "$KC_POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# ─── 1. Read current client_secret from OpenBao ─────────────────────
green "==> read kcadm-admin client_secret from OpenBao ($KV_PATH)"
SECRET=$(bao bao kv get -field=client_secret "$KV_PATH" 2>/dev/null | tr -d '\r\n' || true)
if [ -z "$SECRET" ]; then
    red "    OpenBao read returned empty. Either:"
    red "      - bootstrap the client first (see § Bootstrap caveat in script header), OR"
    red "      - your BAO_TOKEN lacks read capability on $KV_PATH"
    exit 1
fi
green "    secret retrieved ($(printf '%s' "$SECRET" | wc -c) bytes)"

# ─── 2. Authenticate kcadm as kcadm-admin ───────────────────────────
green "==> kcadm config credentials --client $KCADM_CLIENT_ID (master realm)"
if ! kcadm config credentials \
        --server http://localhost:8080 \
        --realm master \
        --client "$KCADM_CLIENT_ID" \
        --secret "$SECRET" >/dev/null 2>&1; then
    red "    kcadm auth failed. Possible causes:"
    red "      - the secret in OpenBao is stale (was rotated outside this script);"
    red "      - kcadm-admin client doesn't exist (run § Bootstrap caveat first);"
    red "      - kcadm-admin client has serviceAccountsEnabled=false (re-check UI)."
    exit 1
fi
green "    auth ok"

# ─── 3. Look up internal IDs we need ─────────────────────────────────
green "==> resolve internal IDs"
KCADM_CID=$(kcadm get clients -r master -q "clientId=$KCADM_CLIENT_ID" \
    --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)
if [ -z "$KCADM_CID" ]; then
    red "    kcadm-admin client not found in master realm. Bootstrap it via the admin UI first."
    exit 1
fi
SA_USER_ID=$(kcadm get "clients/$KCADM_CID/service-account-user" -r master \
    --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)
if [ -z "$SA_USER_ID" ]; then
    red "    kcadm-admin service-account-user not found. The client must have serviceAccountsEnabled=true."
    exit 1
fi
green "    kcadm-admin client id: $KCADM_CID"
green "    kcadm-admin service-account user id: $SA_USER_ID"

# ─── 4. Reconcile role grants (idempotent) ───────────────────────────
#
# ADR-0022 § Roles granted defines the union of roles needed by the four
# migrated scripts. add-roles is idempotent — re-granting an already-
# granted role is a no-op. Adding a new role to this table requires
# appending to the ADR's "Roles granted" section AND extending the
# ROLE_GRANTS array below in the same commit.
#
# Format: <realm-mgmt-client-id>:<role1>,<role2>,...
ROLE_GRANTS=(
    "platform-realm:manage-clients,manage-realm,manage-users,view-realm"
    "secforge-tenants-realm:manage-clients,manage-users,view-realm,view-authorization,view-events"
)

green "==> ensure role grants per ADR-0022 § Roles granted"
for entry in "${ROLE_GRANTS[@]}"; do
    REALM_MGMT_CLIENT="${entry%%:*}"
    ROLES="${entry#*:}"

    # Find the realm-management client's internal ID.
    RM_CID=$(kcadm get clients -r master -q "clientId=$REALM_MGMT_CLIENT" \
        --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)
    if [ -z "$RM_CID" ]; then
        red "    realm-mgmt client '$REALM_MGMT_CLIENT' not found — does the realm exist?"
        exit 1
    fi

    # add-roles per role. The --cclientid flag is the realm-mgmt-client
    # name (e.g., 'platform-realm'); --rolename is the role name on that
    # client. add-roles is idempotent.
    IFS=',' read -r -a ROLE_LIST <<< "$ROLES"
    for role in "${ROLE_LIST[@]}"; do
        if kcadm add-roles -r master \
                --uid "$SA_USER_ID" \
                --cclientid "$REALM_MGMT_CLIENT" \
                --rolename "$role" >/dev/null 2>&1; then
            green "    granted: $REALM_MGMT_CLIENT:$role"
        else
            # add-roles returns non-zero only if the role doesn't exist
            # on the client (typo) or if the role is already granted in
            # some Keycloak versions. Probe for the latter; surface real
            # failures.
            if kcadm get-roles -r master \
                    --uid "$SA_USER_ID" \
                    --cclientid "$REALM_MGMT_CLIENT" 2>/dev/null \
                    | grep -q "\"name\" *: *\"$role\""; then
                yellow "    already granted: $REALM_MGMT_CLIENT:$role"
            else
                red "    FAILED to grant: $REALM_MGMT_CLIENT:$role (does the role exist?)"
                exit 1
            fi
        fi
    done
done

# ─── 5. Optional rotation ────────────────────────────────────────────
if [ "$ROTATE" = "1" ]; then
    green "==> --rotate: regenerate client_secret"
    NEW_SECRET=$(kcadm create "clients/$KCADM_CID/client-secret" -r master -i 2>&1 | tail -1 \
        | sed -E 's/.*"value" *: *"([^"]+)".*/\1/')
    if [ -z "$NEW_SECRET" ] || [ "$NEW_SECRET" = "$SECRET" ]; then
        red "    rotation failed — Keycloak did not return a new secret value"
        exit 1
    fi
    green "    new secret minted ($(printf '%s' "$NEW_SECRET" | wc -c) bytes)"

    green "==> write new secret back to OpenBao at $KV_PATH"
    if ! bao bao kv put "$KV_PATH" client_secret="$NEW_SECRET" >/dev/null 2>&1; then
        red "    OpenBao write failed. The Keycloak-side secret has rotated"
        red "    but OpenBao still holds the OLD value — manual recovery needed."
        red "    Run: kubectl exec -n $NS_BAO $BAO_POD -c openbao -- \\"
        red "             env BAO_TOKEN=\$BAO_TOKEN bao kv put $KV_PATH client_secret='$NEW_SECRET'"
        exit 1
    fi
    green "    OpenBao updated. Future scripts will pick up the new secret on next run."
    SECRET="$NEW_SECRET"

    # Re-authenticate under the new secret so any subsequent step in this
    # run uses the rotated credential.
    yellow "    re-authenticating kcadm as kcadm-admin under the new secret"
    kcadm config credentials \
        --server http://localhost:8080 \
        --realm master \
        --client "$KCADM_CLIENT_ID" \
        --secret "$NEW_SECRET" >/dev/null
fi

green ""
green "kcadm-admin reconciled per ADR-0022."
green "Secret: stored at OpenBao $KV_PATH (client_secret field)"
[ "$ROTATE" = "1" ] && green "Rotation: complete. Next 90-day rotation due: $(date -d '+90 days' +%Y-%m-%d 2>/dev/null || date -v+90d +%Y-%m-%d)"
