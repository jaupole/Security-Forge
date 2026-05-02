#!/usr/bin/env bash
# kcadm-auth.sh — shared helper sourced by the four kcadm-using scripts
# (clients/openbao.sh · clients/kcadm-admin.sh's bootstrap path is NOT
# a consumer · realms/bootstrap-bff-clients.sh · realms/create-tenant-
# test-user.sh · verify.sh) per ADR-0022.
#
# Provides two functions:
#
#   kcadm_admin_fetch_secret
#       Echoes kcadm-admin's client_secret from OpenBao at
#       secret/data/keycloak/clients/kcadm-admin (KV-v2). Requires the
#       caller's environment to set BAO_TOKEN to a token with read
#       capability on that path. Returns non-zero on missing/empty
#       secret.
#
#   kcadm_admin_auth
#       Authenticates kcadm.sh inside the keycloak-0 pod against the
#       master realm using `--client kcadm-admin --secret <fetched>`.
#       Returns non-zero on auth failure with a hint about likely
#       causes (stale secret, missing client, serviceAccountsEnabled
#       false). Requires kcadm-admin to be bootstrapped — see
#       infrastructure/keycloak/clients/kcadm-admin.sh § Bootstrap
#       caveat in its header for the manual UI steps.
#
# Why a shared helper:
#   - All four migrated scripts need the exact same fetch-and-auth
#     sequence. Inline duplication risks drift across scripts (see
#     pre-migration password+TOTP-concat divergence).
#   - The OpenBao read uses the kubectl-exec wrapper pattern from
#     ADR-0022 § Host-side access path option (b). Centralized here so
#     a future cloud-edition migration that swaps the openbao-storage
#     mechanism only edits this file.
#
# Usage from a consumer script:
#
#   set -euo pipefail
#   . "$(dirname "$0")/../_lib/kcadm-auth.sh"   # adjust ../ depth
#   kcadm_admin_auth || exit 1
#   # ... now `kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh <verb>`
#   #     runs as kcadm-admin under the cached session ...

# Constants.
_KCADM_AUTH_NS_BAO=openbao
_KCADM_AUTH_BAO_POD=openbao-0
_KCADM_AUTH_NS_KC=keycloak
_KCADM_AUTH_KC_POD=keycloak-0
_KCADM_AUTH_KV_PATH="secret/keycloak/clients/kcadm-admin"
_KCADM_AUTH_CLIENT_ID=kcadm-admin

_kcadm_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
_kcadm_yel()   { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# kcadm_admin_fetch_secret — echo the client_secret to stdout. Caller
# captures via $(kcadm_admin_fetch_secret).
kcadm_admin_fetch_secret() {
    if [ -z "${BAO_TOKEN:-}" ]; then
        _kcadm_red "BAO_TOKEN env var is required (see ADR-0022 § Host-side access path)"
        return 1
    fi
    local secret
    secret=$(kubectl exec -n "$_KCADM_AUTH_NS_BAO" "$_KCADM_AUTH_BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao kv get -field=client_secret "$_KCADM_AUTH_KV_PATH" 2>/dev/null \
        | tr -d '\r\n')
    if [ -z "$secret" ]; then
        _kcadm_red "OpenBao read at $_KCADM_AUTH_KV_PATH returned empty."
        _kcadm_red "  Either bootstrap kcadm-admin first (see infrastructure/keycloak/clients/kcadm-admin.sh"
        _kcadm_red "  § Bootstrap caveat) or your BAO_TOKEN lacks read capability on $_KCADM_AUTH_KV_PATH."
        return 1
    fi
    printf '%s' "$secret"
}

# kcadm_admin_auth — fetch the secret and run kcadm config credentials.
# The session is cached inside keycloak-0's $HOME/.keycloak/kcadm.config
# so subsequent kcadm calls in the same script reuse it.
kcadm_admin_auth() {
    local secret
    secret=$(kcadm_admin_fetch_secret) || return 1
    if ! kubectl exec -n "$_KCADM_AUTH_NS_KC" "$_KCADM_AUTH_KC_POD" -c keycloak -- \
            /opt/keycloak/bin/kcadm.sh config credentials \
            --server http://localhost:8080 \
            --realm master \
            --client "$_KCADM_AUTH_CLIENT_ID" \
            --secret "$secret" >/dev/null 2>&1; then
        _kcadm_red "kcadm auth failed under client=$_KCADM_AUTH_CLIENT_ID. Likely causes:"
        _kcadm_red "  - the OpenBao-stored secret is stale (was rotated outside the runbook)"
        _kcadm_red "  - kcadm-admin client doesn't exist in master realm (bootstrap it; see"
        _kcadm_red "    infrastructure/keycloak/clients/kcadm-admin.sh § Bootstrap caveat)"
        _kcadm_red "  - kcadm-admin has serviceAccountsEnabled=false (re-check the master-realm UI)"
        return 1
    fi
    return 0
}
