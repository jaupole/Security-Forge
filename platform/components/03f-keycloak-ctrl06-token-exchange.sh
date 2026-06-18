#!/usr/bin/env bash
# 03f — Keycloak CTRL-06 token-exchange day-2 apply (2026-06-18)
#
# Retires "shared-audience trust": Ecosystem Control (CONTROL_EXCHANGE_MODE=require,
# set in platform/manifests/control/09-backend-deployment.yaml) only accepts tokens
# an app deliberately exchanged (RFC 8693) for aud=control. This script applies the
# Keycloak side of that to the secforge-tenants realm. The realm-import YAML is
# ONE-SHOT, so on a live/rebuilt cluster these client-scope + mapper edits must land
# here (idempotent — safe to re-run; re-runs are no-ops).
#
# Declarative source of truth stays aligned in
# platform/manifests/keycloak/realms/secforge-tenants-realm.yaml — but the OPTIONAL
# client scope below cannot be expressed safely inside the one-shot import (a partial
# `clientScopes:` block can clobber Keycloak's built-in default scopes), so the scope
# itself is OWNED here. The YAML carries STE=true + the self-audience mappers; this
# script adds control-aud and removes the legacy static control mappers.
#
# WHAT THIS APPLIES (secforge-tenants realm; the app clients are tenant-realm-only —
# they do NOT exist in the platform realm, so there is no platform-realm path):
#   - standard.token.exchange.enabled = true on the 4 app clients (member-hub,
#     proposal-forge, project-manager, business-manager).
#   - an OPTIONAL client scope `control-aud` carrying an oidc-audience-mapper
#     (included.custom.audience=control), assigned OPTIONAL to the 4 app clients.
#       → a default (un-scoped) app token carries NO aud=control; only an exchange
#         that requests `scope=control-aud` mints it. That is the security goal.
#   - removal of any legacy static `control-audience-for-getme` mapper (the old
#     arrangement that stamped aud=control on EVERY token, defeating require).
#
# The apps request the scope via @jaupole/ecosystem-auth >= 0.1.10
# (controlAudience='control' + controlExchangeScope='control-aud'; the lib also
# exchanges on DIRECT Control calls via exchangeControlToken()).
#
# WHEN TO RUN:
#   - After a realm rebuild/import, before flipping Control to require (or any time
#     this KC state has drifted). Order vs app deploys is not load-bearing while
#     Control is in accept; it IS required before require.
#
# AUTH: uses the `control-admin` service account (realm-admin in secforge-tenants;
# secret KEYCLOAK_TENANTS_ADMIN_CLIENT_SECRET in k8s Secret control-app-secrets, ns
# control) against the admin REST API at https://kc.${DOMAIN}. Self-contained — no
# kcadm cached-config prerequisite (unlike 03a/03d). The bootstrap temp-admin is
# disabled, which is why this path is used.
#
# ENV: DOMAIN (default secforge.dev). Requires kubectl + curl + jq + cluster access.

set -euo pipefail
IFS=$'\n\t'

DOMAIN="${DOMAIN:-secforge.dev}"
REALM="secforge-tenants"
KC="https://kc.${DOMAIN}/admin/realms/${REALM}"
TOKEN_URL="https://auth.${DOMAIN}/realms/${REALM}/protocol/openid-connect/token"
APP_CLIENTS=(member-hub proposal-forge project-manager business-manager)

echo ">>> [00] Acquire control-admin token"
SECRET=$(kubectl get secret control-app-secrets -n control \
  -o jsonpath='{.data.KEYCLOAK_TENANTS_ADMIN_CLIENT_SECRET}' | base64 -d)
TOKEN=$(curl -s -X POST "$TOKEN_URL" \
  -d grant_type=client_credentials -d client_id=control-admin -d client_secret="$SECRET" \
  | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "FATAL: could not obtain control-admin token" >&2; exit 1; }
auth="Authorization: Bearer $TOKEN"

echo ">>> [01] Ensure optional client scope 'control-aud' (+ audience mapper)"
SCOPE_ID=$(curl -s "$KC/client-scopes" -H "$auth" | jq -r '.[]|select(.name=="control-aud")|.id')
if [ -z "$SCOPE_ID" ]; then
  curl -s -o /dev/null -w "    create-scope HTTP %{http_code}\n" -X POST "$KC/client-scopes" \
    -H "$auth" -H "Content-Type: application/json" -d '{
      "name":"control-aud","protocol":"openid-connect",
      "description":"CTRL-06: optional scope stamping aud=control for RFC8693 exchange to Ecosystem Control",
      "attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}'
  SCOPE_ID=$(curl -s "$KC/client-scopes" -H "$auth" | jq -r '.[]|select(.name=="control-aud")|.id')
else
  echo "    control-aud already present ($SCOPE_ID)"
fi
HAS_MAP=$(curl -s "$KC/client-scopes/$SCOPE_ID/protocol-mappers/models" -H "$auth" \
  | jq '[.[]|select(.protocolMapper=="oidc-audience-mapper" and .config["included.custom.audience"]=="control")]|length')
if [ "$HAS_MAP" = "0" ]; then
  curl -s -o /dev/null -w "    create-mapper HTTP %{http_code}\n" \
    -X POST "$KC/client-scopes/$SCOPE_ID/protocol-mappers/models" \
    -H "$auth" -H "Content-Type: application/json" -d '{
      "name":"control-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
      "config":{"included.custom.audience":"control","access.token.claim":"true","id.token.claim":"false"}}'
else
  echo "    scope audience mapper already present"
fi

for c in "${APP_CLIENTS[@]}"; do
  CID=$(curl -s "$KC/clients?clientId=$c" -H "$auth" | jq -r '.[0].id // empty')
  if [ -z "$CID" ]; then echo ">>> [$c] WARNING: client not found — skipping" >&2; continue; fi
  echo ">>> [$c] ($CID)"

  # standard token exchange
  STE=$(curl -s "$KC/clients?clientId=$c" -H "$auth" | jq -r '.[0].attributes["standard.token.exchange.enabled"] // "false"')
  if [ "$STE" != "true" ]; then
    curl -s -o /dev/null -w "    enable STE HTTP %{http_code}\n" -X PUT "$KC/clients/$CID" \
      -H "$auth" -H "Content-Type: application/json" \
      -d '{"attributes":{"standard.token.exchange.enabled":"true"}}'
  else echo "    STE already true"; fi

  # assign control-aud as OPTIONAL (PUT is idempotent)
  curl -s -o /dev/null -w "    assign control-aud (optional) HTTP %{http_code}\n" \
    -X PUT "$KC/clients/$CID/optional-client-scopes/$SCOPE_ID" -H "$auth"

  # remove any legacy static control-audience mapper
  MID=$(curl -s "$KC/clients/$CID/protocol-mappers/models" -H "$auth" \
    | jq -r '.[]|select(.protocolMapper=="oidc-audience-mapper" and .config["included.custom.audience"]=="control")|.id')
  if [ -n "$MID" ]; then
    curl -s -o /dev/null -w "    delete static control mapper HTTP %{http_code}\n" \
      -X DELETE "$KC/clients/$CID/protocol-mappers/models/$MID" -H "$auth"
  else echo "    no static control mapper (good)"; fi
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  CTRL-06 Keycloak state applied (secforge-tenants)."
echo "  Verify: a default app token has no aud=control; an exchange"
echo "  with scope=control-aud yields aud=control; Control require"
echo "  rejects the former (401) and accepts the latter."
echo "════════════════════════════════════════════════════════════"
