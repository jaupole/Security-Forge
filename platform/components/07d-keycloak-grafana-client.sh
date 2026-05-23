#!/usr/bin/env bash
# 07d — Create the `grafana` OIDC client in the Keycloak `platform` realm.
#
# ╔══════════════════════════════════════════════════════════════════╗
# ║  DEPRECATED 2026-05-23 (backlog #59).                            ║
# ║                                                                  ║
# ║  Now declared in platform/manifests/keycloak/realms/              ║
# ║  platform-realm.yaml (`spec.realm.clients[]`); operator creates  ║
# ║  it at realm-import on greenfield. Like 05h, this script's       ║
# ║  kcadm auth path is broken since the 2026-05-21 temp-admin       ║
# ║  deletion. See project_keycloak_realm_import_codification for    ║
# ║  the new pattern and #60 for the secret-publishing follow-up.    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# ━━━━ Historical documentation (when this script DID work) ━━━━
#
# Modeled after 05h-keycloak-openbao-client.sh — same bootstrap-admin auth
# pattern, no master-realm UI step needed.
#
# Stores the auto-generated client_secret into K8s Secret
# `keycloak/keycloak-grafana-client-secret` (consumed by 07e for the KPS
# deployment via OpenBao + VSO).
#
# Idempotent — if the client already exists, regenerates its secret and
# updates the K8s Secret.

echo "ERROR: 07d-keycloak-grafana-client.sh is DEPRECATED (backlog #59)." >&2
echo "       The grafana client is now declared in platform-realm.yaml." >&2
echo "       This script's kcadm auth path is broken since temp-admin" >&2
echo "       deletion (2026-05-21). See script header for full context." >&2
exit 1

# ━━━━ Original implementation preserved below for reference only ━━━━

set -euo pipefail

NS=keycloak
KC_POD=keycloak-0
REALM=platform

# shellcheck disable=SC1091
set -a; source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)/../globals.env"; set +a

# Read Keycloak admin creds from operator-generated Secret
ADMIN_USER=$(kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)

kc() {
  kubectl exec -n "$NS" "$KC_POD" -c keycloak -- /opt/keycloak/bin/kcadm.sh "$@"
}

# Login (writes ~/.keycloak/kcadm.config in the pod, ephemeral)
echo ">>> Authenticating kcadm against master realm"
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null
unset ADMIN_PASS

# NOTE: No platform_admin realm role pre-check. Production Grafana role
# mapping uses preferred_username (single-user workaround) per
# values/kube-prometheus-stack.yaml's role_attribute_path. If we ever flip
# to realm-role mapping (Phase 7d follow-up), reinstate the role-existence
# check here.

# Build client JSON. Confidential client-secret + standardFlow + PKCE S256.
# Default scopes include `roles` so realm_access.roles is in tokens; chart's
# grafana.ini `role_attribute_path` reads it for Admin mapping.
CLIENT_JSON=$(cat <<EOF
{
  "clientId": "grafana",
  "name": "Grafana",
  "description": "OIDC federation for Grafana platform-admin login",
  "enabled": true,
  "protocol": "openid-connect",
  "rootUrl": "https://grafana.${DOMAIN}",
  "baseUrl": "https://grafana.${DOMAIN}",
  "redirectUris": [
    "https://grafana.${DOMAIN}/login/generic_oauth"
  ],
  "webOrigins": ["https://grafana.${DOMAIN}"],
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
    "post.logout.redirect.uris": "https://grafana.${DOMAIN}",
    "pkce.code.challenge.method": "S256",
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

# Stage JSON into pod and create or update
echo "$CLIENT_JSON" | kubectl exec -i -n "$NS" "$KC_POD" -c keycloak -- /bin/sh -c 'cat > /tmp/grafana-client.json'

echo ">>> Looking up existing grafana client (if any)"
EXISTING_ID=$(kc get clients -r "$REALM" -q clientId=grafana --fields id 2>/dev/null \
              | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1 || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo "    client exists (id=$EXISTING_ID); updating"
  kc update "clients/$EXISTING_ID" -r "$REALM" -f /tmp/grafana-client.json
  CLIENT_ID="$EXISTING_ID"
else
  echo ">>> Creating grafana client in realm $REALM"
  CREATE_OUT=$(kc create clients -r "$REALM" -f /tmp/grafana-client.json 2>&1)
  CLIENT_ID=$(echo "$CREATE_OUT" | grep -oP "with id '\K[^']+" | head -1)
  if [[ -z "$CLIENT_ID" ]]; then
    echo "ERROR: could not extract client ID from kcadm output:" >&2
    echo "$CREATE_OUT" >&2
    exit 1
  fi
  echo "    created (id=$CLIENT_ID)"
fi

# Retrieve client_secret. Pipe directly into the Secret; never display.
echo ">>> Retrieving client_secret and writing K8s Secret keycloak/keycloak-grafana-client-secret"
SECRET_VALUE=$(kc get "clients/$CLIENT_ID/client-secret" -r "$REALM" 2>/dev/null \
               | grep -oP '"value"\s*:\s*"\K[^"]+' | head -1)

if [[ -z "$SECRET_VALUE" ]]; then
  echo "ERROR: could not retrieve client_secret" >&2
  exit 1
fi

kubectl -n keycloak create secret generic keycloak-grafana-client-secret \
  --from-literal=client_id=grafana \
  --from-literal=client_secret="$SECRET_VALUE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n keycloak label secret keycloak-grafana-client-secret \
  app.kubernetes.io/name=grafana \
  secforge.platform/component=keycloak \
  secforge.platform/purpose=oidc-client-secret \
  --overwrite >/dev/null

unset SECRET_VALUE CLIENT_JSON

# Clean up kcadm session in the pod
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /opt/keycloak/.keycloak/kcadm.config 2>/dev/null || true
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /tmp/grafana-client.json 2>/dev/null || true

cat <<EOF

✓ Keycloak grafana OIDC client created in realm $REALM.
  Client ID:        grafana
  Client UUID:      $CLIENT_ID
  Client secret:    stored in Secret keycloak/keycloak-grafana-client-secret
  Redirect URI:     https://grafana.${DOMAIN}/login/generic_oauth

Next: bash 07e-prometheus.sh
  (07e reads keycloak-grafana-client-secret, stages it in OpenBao at
   secret/grafana/oidc, applies the VSO binding in observability ns,
   and deploys kube-prometheus-stack with OIDC-federated Grafana login.)
EOF
