#!/usr/bin/env bash
# 03e — Flip control-portal public → confidential (Portal BFF cutover)
#
# Phase 4 of the centralized-login program: Ecosystem Control becomes the
# Portal's Backend-for-Frontend. control-portal stops being a public SPA client
# (tokens in the browser) and becomes a CONFIDENTIAL client whose secret Control
# holds server-side. The declarative source of truth is the two realm-import
# YAMLs (platform-realm.yaml / secforge-tenants-realm.yaml); realm-import is
# one-shot, so this kcadm replay applies the same change to the LIVE cluster.
#
# ⚠️  DESTRUCTIVE TO THE CURRENT PUBLIC-SPA LOGIN. Run this ONLY as part of the
#     Phase 4 deploy — i.e. together with the Control image that mounts the BFF
#     (/api/auth/*) and the Portal SPA build that redirects to it. Running it
#     while the old public-SPA Portal is still live breaks operator/tenant
#     sign-in (the SPA can't do confidential-client PKCE).
#
# AFTER THIS SCRIPT: publish the regenerated client secret(s) so Control can
# read them. This script prints each realm's secret; feed them to
# 05l-keycloak-secret-publish.sh → OpenBao → VSO → Control env
# (CONTROL_PORTAL_CLIENT_SECRET for platform, CONTROL_PORTAL_CLIENT_SECRET_TENANTS
# for secforge-tenants).
#
# AUTH PREREQUISITE: kcadm cached in keycloak-0 (see 03a's header).
# ENV: DOMAIN (default secforge.dev).

set -euo pipefail
IFS=$'\n\t'

KEYCLOAK_POD="keycloak-0"
KEYCLOAK_NS="keycloak"
DOMAIN="${DOMAIN:-secforge.dev}"

kc() {
  kubectl -n "$KEYCLOAK_NS" exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh "$@"
}

# Flip control-portal in one realm. Args: $1 realm  $2 shell_host (admin/portal host)
flip() {
  local realm="$1" shell_host="$2"

  if ! kc get "realms/$realm" >/dev/null 2>&1; then
    echo "WARNING: realm '$realm' does not exist — skipping." >&2
    return 0
  fi
  local id
  id=$(kc get clients -r "$realm" -q "clientId=control-portal" --fields id --format csv --noquotes 2>/dev/null | head -1 || true)
  if [[ -z "$id" ]]; then
    echo "WARNING: control-portal not found in realm '$realm' — skipping." >&2
    return 0
  fi

  echo ">>> [$realm] flip control-portal → confidential + BFF redirect/backchannel"
  kc update "clients/$id" -r "$realm" \
    -s 'publicClient=false' \
    -s 'clientAuthenticatorType=client-secret' \
    -s "redirectUris=[\"https://${shell_host}/api/auth/callback\",\"https://control.${DOMAIN}/api/auth/callback\"]" \
    -s 'attributes."pkce.code.challenge.method"=S256' \
    -s "attributes.\"backchannel.logout.url\"=https://${shell_host}/api/auth/backchannel-logout"

  # Ensure a `control` audience mapper exists (idempotent).
  if ! kc get "clients/$id/protocol-mappers/models" -r "$realm" \
        | jq -e '.[] | select(.config["included.custom.audience"]=="control")' >/dev/null 2>&1; then
    echo "    adding control audience mapper"
    kc create "clients/$id/protocol-mappers/models" -r "$realm" \
      -s 'name=control-audience' \
      -s 'protocol=openid-connect' \
      -s 'protocolMapper=oidc-audience-mapper' \
      -s 'config."included.custom.audience"=control' \
      -s 'config."access.token.claim"=true' \
      -s 'config."id.token.claim"=false'
  else
    echo "    control audience mapper already present"
  fi

  # Regenerate + emit the confidential secret for 05l to publish.
  local secret
  secret=$(kc create "clients/$id/client-secret" -r "$realm" --fields value --format csv --noquotes 2>/dev/null | head -1 || true)
  echo "    NEW control-portal secret ($realm): ${secret:-<unchanged — fetch via kcadm get clients/$id/client-secret>}"
  echo "    → publish via 05l: $( [[ "$realm" == "secforge-tenants" ]] && echo CONTROL_PORTAL_CLIENT_SECRET_TENANTS || echo CONTROL_PORTAL_CLIENT_SECRET )"
}

echo ">>> [00] Verify kcadm cache is populated"
if ! kc get serverinfo --fields systemInfo >/dev/null 2>&1; then
  echo "FATAL: kcadm not authenticated. See AUTH PREREQUISITE in 03a's header." >&2
  exit 1
fi

flip "platform"         "admin.${DOMAIN}"
flip "secforge-tenants" "portal.${DOMAIN}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  control-portal BFF flip complete. Publish the secret(s) via 05l,"
echo "  then bounce keycloak-0 to flush the Infinispan client cache"
echo "  (direct kcadm client edits don't always invalidate it)."
echo "════════════════════════════════════════════════════════════"
