#!/usr/bin/env bash
# 05h — Create the `openbao` OIDC client in the Keycloak `platform` realm.
#
# ╔══════════════════════════════════════════════════════════════════╗
# ║  DEPRECATED 2026-05-23 (backlog #59).                            ║
# ║                                                                  ║
# ║  The `openbao` client is now declared in                         ║
# ║  platform/manifests/keycloak/realms/platform-realm.yaml          ║
# ║  (`spec.realm.clients[]`) and gets created by the Keycloak       ║
# ║  Operator at realm-import time on greenfield install.            ║
# ║                                                                  ║
# ║  This script is preserved for historical reference only. It      ║
# ║  WILL FAIL when run, because the kcadm auth path below reads     ║
# ║  the `keycloak-initial-admin` Secret which holds `temp-admin`    ║
# ║  credentials — and that user was DB-deleted on 2026-05-21 by     ║
# ║  `99-cleanup-2026-05-21-temp-admin.sh`. There is no scriptable   ║
# ║  admin path remaining (jaupole's WebAuthn requirement blocks     ║
# ║  kcadm direct-grant). See project_keycloak_admin_db_only.        ║
# ║                                                                  ║
# ║  Greenfield bootstrap of openbao OIDC:                           ║
# ║    1. Realm-import creates the client with an operator-          ║
# ║       generated random secret.                                   ║
# ║    2. (Future #60) A secret-publishing step extracts that        ║
# ║       value into the consumer Secret                             ║
# ║       `openbao/keycloak-openbao-client-secret`.                  ║
# ║    3. `05i-openbao-oidc-auth.sh` reads from that consumer        ║
# ║       Secret to wire up OpenBao's OIDC auth method.              ║
# ║                                                                  ║
# ║  DR (Velero restore) bootstrap of openbao OIDC: the consumer     ║
# ║  Secret already exists in backup; restored Keycloak DB has the   ║
# ║  matching CLIENT.secret row — no scripting needed.               ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# ━━━━ Historical documentation (when this script DID work) ━━━━
#
# Stores the auto-generated client_secret into K8s Secret
# `openbao/keycloak-openbao-client-secret` (consumed by 05i for OpenBao
# OIDC auth method config).
#
# Authenticates to Keycloak via the operator-generated keycloak-initial-admin
# Secret. The client_secret never appears on stdout; flows directly from
# kcadm output into the Secret create.
#
# Idempotent — if the client already exists, regenerates its secret and
# updates the K8s Secret.

echo "ERROR: 05h-keycloak-openbao-client.sh is DEPRECATED (backlog #59)." >&2
echo "       The openbao client is now declared in platform-realm.yaml" >&2
echo "       and gets created by the Keycloak Operator at realm-import." >&2
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

# Build client JSON
CLIENT_JSON=$(cat <<EOF
{
  "clientId": "openbao",
  "name": "OpenBao",
  "description": "OpenBao OIDC auth for the platform realm (admin operators)",
  "enabled": true,
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "implicitFlowEnabled": false,
  "serviceAccountsEnabled": false,
  "redirectUris": [
    "https://bao.${DOMAIN}/ui/vault/auth/oidc/oidc/callback",
    "https://bao.${DOMAIN}/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "webOrigins": ["+"],
  "attributes": {
    "post.logout.redirect.uris": "+"
  }
}
EOF
)

# Stage JSON into pod and create or update
echo "$CLIENT_JSON" | kubectl exec -i -n "$NS" "$KC_POD" -c keycloak -- /bin/sh -c 'cat > /tmp/openbao-client.json'

echo ">>> Looking up existing openbao client (if any)"
EXISTING_ID=$(kc get clients -r "$REALM" -q clientId=openbao --fields id 2>/dev/null \
              | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1 || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo "    client exists (id=$EXISTING_ID); updating"
  kc update "clients/$EXISTING_ID" -r "$REALM" -f /tmp/openbao-client.json
  CLIENT_ID="$EXISTING_ID"
else
  echo ">>> Creating openbao client in realm $REALM"
  CREATE_OUT=$(kc create clients -r "$REALM" -f /tmp/openbao-client.json 2>&1)
  CLIENT_ID=$(echo "$CREATE_OUT" | grep -oP "with id '\K[^']+" | head -1)
  if [[ -z "$CLIENT_ID" ]]; then
    echo "ERROR: could not extract client ID from kcadm output:" >&2
    echo "$CREATE_OUT" >&2
    exit 1
  fi
  echo "    created (id=$CLIENT_ID)"
fi

# Retrieve (and rotate) client_secret. Pipe directly into the Secret;
# never display it.
echo ">>> Retrieving client_secret and writing K8s Secret openbao/keycloak-openbao-client-secret"
SECRET_VALUE=$(kc get "clients/$CLIENT_ID/client-secret" -r "$REALM" 2>/dev/null \
               | grep -oP '"value"\s*:\s*"\K[^"]+' | head -1)

if [[ -z "$SECRET_VALUE" ]]; then
  echo "ERROR: could not retrieve client_secret" >&2
  exit 1
fi

kubectl -n openbao create secret generic keycloak-openbao-client-secret \
  --from-literal=client_id=openbao \
  --from-literal=client_secret="$SECRET_VALUE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n openbao label secret keycloak-openbao-client-secret \
  app.kubernetes.io/name=openbao \
  secforge.platform/component=openbao \
  secforge.platform/purpose=oidc-client-secret \
  --overwrite >/dev/null

unset SECRET_VALUE CLIENT_JSON

# Clean up kcadm session in the pod
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /opt/keycloak/.keycloak/kcadm.config 2>/dev/null || true
kubectl exec -n "$NS" "$KC_POD" -c keycloak -- rm -f /tmp/openbao-client.json 2>/dev/null || true

cat <<EOF

✓ Keycloak openbao OIDC client created in realm $REALM.
  Client ID:        openbao
  Client UUID:      $CLIENT_ID
  Client secret:    stored in Secret openbao/keycloak-openbao-client-secret
  Redirect URIs:    https://bao.${DOMAIN}/ui/vault/auth/oidc/oidc/callback,
                    https://bao.${DOMAIN}/oidc/callback,
                    http://localhost:8250/oidc/callback

Next: bash 05i-openbao-oidc-auth.sh
EOF
