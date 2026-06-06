#!/usr/bin/env bash
# 03d — Keycloak client hardening replay (centralized-login program, 2026-06-06)
#
# Day-2 replay for the client-level changes the centralized-login (BFF) program
# adds to the user-facing app clients. Realm-import is ONE-SHOT, so edits to
# already-imported clients on a live cluster must land via kcadm here (same
# mechanism + auth prerequisite as 03a-keycloak-realm-hardening.sh). The
# corresponding declarative source of truth is in the realm-import YAMLs at
# platform/manifests/keycloak/realms/{platform,secforge-tenants}-realm.yaml —
# both must stay aligned; if you change one, change the other.
#
# WHAT THIS APPLIES (member-hub + proposal-forge, BOTH realms):
#   - pkce.code.challenge.method = S256
#       Enforce PKCE S256 server-side. The @jaupole/ecosystem-auth BFF already
#       always sends an S256 challenge; this rejects any non-PKCE / plain
#       downgrade. Safe to apply before/after the apps deploy.
#   - backchannel.logout.url = https://<app-host>/.../auth/backchannel-logout
#       Keycloak POSTs a logout_token here when the SSO session ends, so the
#       app revokes its server-side session (true single-logout). Safe to apply
#       even before the app's receiver is deployed — Keycloak just logs a
#       delivery warning and the logout still completes.
#
# NOT covered here (Phase-4-coupled, ships WITH the Control BFF code):
#   - control-portal public→confidential flip + `control` audience mapper +
#     backchannel.logout.url. Flipping it live without the BFF deployed breaks
#     the current public-SPA admin console, so it lives in the Phase 4 change
#     set (paired with 05l-keycloak-secret-publish.sh to push the new secret
#     into OpenBao→VSO→Control env). Do NOT add it here.
#
# WHEN TO RUN:
#   - After the Member Hub + Proposal Forge BFF images are deployed (or just
#     before — order is not load-bearing, see above).
#   - On any day-2 cluster where these client attributes have drifted.
#
# USAGE:
#   ./03d-keycloak-client-hardening.sh                  # both realms
#   ./03d-keycloak-client-hardening.sh platform         # platform only
#   ./03d-keycloak-client-hardening.sh secforge-tenants # tenants only
#
# AUTH PREREQUISITE: identical to 03a — kcadm credentials cached in keycloak-0
# at ~/.keycloak/kcadm.config (config credentials against the master realm with
# a real admin). See 03a's header / the realm-hardening-replay runbook.
#
# ENV:
#   DOMAIN  Public apex domain for the app hosts. Default: secforge.dev.

set -euo pipefail
IFS=$'\n\t'

KEYCLOAK_POD="keycloak-0"
KEYCLOAK_NS="keycloak"
DOMAIN="${DOMAIN:-secforge.dev}"

kc() {
  kubectl -n "$KEYCLOAK_NS" exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh "$@"
}

# Set the two BFF attributes on one client in one realm. Idempotent (kcadm
# does a get-merge-put for -s, so other attributes are preserved and re-runs
# are no-ops). Skips with a warning when the client or realm is absent — this
# can run during a phased Shape-B rollout.
#
# Args: $1 realm   $2 clientId   $3 backchannel_logout_url
harden_client() {
  local realm="$1" client_id="$2" bc_url="$3"

  if ! kc get "realms/$realm" >/dev/null 2>&1; then
    echo "WARNING: realm '$realm' does not exist — skipping." >&2
    return 0
  fi

  local id
  id=$(kc get clients -r "$realm" -q "clientId=$client_id" --fields id --format csv --noquotes 2>/dev/null | head -1 || true)
  if [[ -z "$id" ]]; then
    echo "WARNING: client '$client_id' not found in realm '$realm' — skipping." >&2
    return 0
  fi

  echo ">>> [$realm/$client_id] enforce PKCE S256 + backchannel.logout.url"
  kc update "clients/$id" -r "$realm" \
    -s 'attributes."pkce.code.challenge.method"=S256' \
    -s "attributes.\"backchannel.logout.url\"=$bc_url"

  echo "    current state:"
  kc get "clients/$id" -r "$realm" \
    | jq '{clientId, publicClient, pkce: .attributes."pkce.code.challenge.method", backchannelLogoutUrl: .attributes."backchannel.logout.url"}'
}

harden_realm_clients() {
  local realm="$1"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Client hardening: realm $realm"
  echo "════════════════════════════════════════════════════════════"
  harden_client "$realm" "member-hub"     "https://members.${DOMAIN}/auth/backchannel-logout"
  harden_client "$realm" "proposal-forge" "https://pf.${DOMAIN}/api/v1/auth/backchannel-logout"
}

# ─── Preflight ────────────────────────────────────────────────────────────
echo ">>> [00] Verify kcadm cache is populated"
if ! kc get serverinfo --fields systemInfo >/dev/null 2>&1; then
  echo "FATAL: kcadm not authenticated. See AUTH PREREQUISITE in 03a's header." >&2
  exit 1
fi

# ─── Dispatch ─────────────────────────────────────────────────────────────
TARGET="${1:-all}"
case "$TARGET" in
  platform)         harden_realm_clients "platform" ;;
  secforge-tenants) harden_realm_clients "secforge-tenants" ;;
  all)
    harden_realm_clients "platform"
    harden_realm_clients "secforge-tenants"
    ;;
  *)
    echo "Unknown realm '$TARGET'. Valid: platform, secforge-tenants, all (default)" >&2
    exit 2
    ;;
esac

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Client hardening replay complete."
echo "════════════════════════════════════════════════════════════"
