#!/usr/bin/env bash
# 07i — Create the `wazuh-dashboard` OIDC client in Keycloak's `platform`
# realm + stage the OIDC config bundle in OpenBao for VSO consumption.
#
# Deltas from the retired local-edition client script:
#   - Auth via keycloak-initial-admin Secret (no kcadm-admin-tmp pattern)
#   - secforge.local → ${DOMAIN}
#   - No platform_admin realm-role pre-check (production uses
#     subject_key=preferred_username + roles_mapping.users in OpenSearch
#     security, mirroring the Grafana/OpenBao single-user workaround)
#   - PKCE NOT enforced — Wazuh's OpenSearch Dashboards OIDC plugin
#     (Wazuh 4.14.4 / OpenSearch 2.16.x) doesn't send code_challenge_method.
#     With PKCE required Keycloak rejects with `invalid_request: Missing
#     parameter: code_challenge_method` and the dashboard restarts the OIDC
#     flow → ERR_TOO_MANY_REDIRECTS in the browser. Other clients (OpenBao,
#     Grafana) keep PKCE S256 because they DO support it.
#
# Outputs:
#   - K8s Secret keycloak/keycloak-wazuh-client-secret (client_id + secret)
#   - OpenBao secret/data/wazuh/oidc with keys
#       client_id, client_secret, issuer, redirect_uri
#
# Pre-conditions:
#   - openbao-root-token-tmp Secret in openbao ns
#
# Idempotent.

set -euo pipefail

NS=keycloak
KC_POD=keycloak-0
NS_BAO=openbao
POD_BAO=openbao-0
REALM=platform
CLIENT_ID=wazuh-dashboard

# shellcheck disable=SC1091
set -a; source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)/../globals.env"; set +a

DASHBOARD_URL="https://wazuh.${DOMAIN}"
ISSUER="https://auth.${DOMAIN}/realms/${REALM}"
REDIRECT_URI="${DASHBOARD_URL}/auth/openid/login"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found."; exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
ADMIN_USER=$(kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)

kc() {
  kubectl exec -n "$NS" "$KC_POD" -c keycloak -- /opt/keycloak/bin/kcadm.sh "$@"
}
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

green "==> kcadm authenticate"
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null
unset ADMIN_PASS

# ─── wazuh-dashboard client representation ────────────────────────────
CLIENT_JSON=$(cat <<EOF
{
  "clientId": "${CLIENT_ID}",
  "name": "Wazuh Dashboard",
  "description": "OIDC federation for Wazuh OpenSearch Dashboards login",
  "enabled": true,
  "protocol": "openid-connect",
  "rootUrl": "${DASHBOARD_URL}",
  "baseUrl": "${DASHBOARD_URL}",
  "redirectUris": [
    "${REDIRECT_URI}"
  ],
  "webOrigins": ["${DASHBOARD_URL}"],
  "publicClient": false,
  "bearerOnly": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": true,
  "fullScopeAllowed": false,
  "attributes": {
    "post.logout.redirect.uris": "${DASHBOARD_URL}",
    "use.refresh.tokens": "true",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "user.info.signed.response.alg": "RS256",
    "client_credentials.use_refresh_token": "false",
    "use.jwks.url": "false",
    "dpop.bound.access.tokens": "false"
  },
  "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
  "optionalClientScopes": ["offline_access", "address", "phone", "microprofile-jwt"]
}
EOF
)

green "==> ensure $CLIENT_ID client in $REALM realm"
echo "$CLIENT_JSON" | kubectl exec -i -n "$NS" "$KC_POD" -c keycloak -- /bin/sh -c 'cat > /tmp/wazuh-client.json'

EXISTING_ID=$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id 2>/dev/null \
              | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1 || true)

if [[ -n "$EXISTING_ID" ]]; then
  yellow "    already present (id=$EXISTING_ID); updating"
  kc update "clients/$EXISTING_ID" -r "$REALM" -f /tmp/wazuh-client.json >/dev/null
  INTERNAL_ID="$EXISTING_ID"
else
  green "    creating"
  CREATE_OUT=$(kc create clients -r "$REALM" -f /tmp/wazuh-client.json 2>&1)
  INTERNAL_ID=$(echo "$CREATE_OUT" | grep -oP "with id '\K[^']+" | head -1)
  if [[ -z "$INTERNAL_ID" ]]; then
    red "ERROR: could not extract client ID from kcadm output:"; echo "$CREATE_OUT" >&2; exit 1
  fi
  green "    created (id=$INTERNAL_ID)"
fi

# ─── client_secret ────────────────────────────────────────────────────
green "==> retrieving client_secret"
SECRET_VALUE=$(kc get "clients/$INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null \
               | grep -oP '"value"\s*:\s*"\K[^"]+' | head -1)
if [[ -z "$SECRET_VALUE" ]]; then
  red "ERROR: could not retrieve client_secret"; exit 1
fi

# ─── persist to K8s Secret (Keycloak ns) ─────────────────────────────
green "==> writing K8s Secret keycloak/keycloak-wazuh-client-secret"
kubectl -n keycloak create secret generic keycloak-wazuh-client-secret \
  --from-literal=client_id="$CLIENT_ID" \
  --from-literal=client_secret="$SECRET_VALUE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n keycloak label secret keycloak-wazuh-client-secret \
  app.kubernetes.io/name=wazuh \
  secforge.platform/component=keycloak \
  secforge.platform/purpose=oidc-client-secret \
  --overwrite >/dev/null

# ─── persist to OpenBao for VSO consumption ──────────────────────────
green "==> persist OIDC config bundle to secret/data/wazuh/oidc"
bao bao kv put secret/wazuh/oidc \
  client_id="$CLIENT_ID" \
  client_secret="$SECRET_VALUE" \
  issuer="$ISSUER" \
  redirect_uri="$REDIRECT_URI" >/dev/null

unset SECRET_VALUE CLIENT_JSON ROOT_TOKEN

# Cleanup kcadm session in pod
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /opt/keycloak/.keycloak/kcadm.config 2>/dev/null || true
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /tmp/wazuh-client.json 2>/dev/null || true

cat <<EOF

✓ Keycloak wazuh-dashboard OIDC client provisioned.
  Client ID:        $CLIENT_ID
  Client UUID:      $INTERNAL_ID
  Client secret:    K8s Secret keycloak/keycloak-wazuh-client-secret
                  + OpenBao secret/data/wazuh/oidc (with issuer + redirect_uri)
  Redirect URI:     $REDIRECT_URI

Next:
  - Apply VSO binding:
      kubectl apply -f manifests/wazuh/03-vso-binding.yaml
  - Create wazuh-vso K8s auth role + run 07j-wazuh-oidc-configure.sh
EOF
