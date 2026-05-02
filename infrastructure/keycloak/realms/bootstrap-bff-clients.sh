#!/usr/bin/env bash
# Phase 3.5 — register the four BFF clients in the `secforge-tenants` realm.
#
# Idempotent:
#   - Generates a fresh RSA-2048 keypair per client only if the K8s Secret
#     in the `app` namespace doesn't already exist.
#   - Re-runs against existing Keycloak clients with `kcadm update`,
#     which is also idempotent.
#
# What this creates:
#   - `app/bff-jwt-{client_id}` Secrets with `private.pem` + `public.pem`.
#   - Four Keycloak clients in realm `secforge-tenants`, each:
#     * confidential
#     * client_authenticator_type: client-jwt (private_key_jwt)
#     * Authorization Code + PKCE-S256 + PAR + DPoP required
#     * implicit, ROPC, device, CIBA all disabled
#     * refresh-token rotation with reuse detection (already realm-level)
#     * fullScopeAllowed: false (clients get only what they ask for)
#
# Phase 5 migrates the JWT private keys from K8s Secrets to OpenBao.
#
# Auth (per ADR-0022): set BAO_TOKEN to an OpenBao token with read on
# secret/data/keycloak/clients/kcadm-admin. Authentication via
# kcadm-admin (master-realm service-account client). The legacy
# bootstrap-admin path was retired in commit phase-3-fu (3/4) — see
# ADR-0022 for the rationale.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/realms/bootstrap-bff-clients.sh

set -euo pipefail

# shellcheck source=../_lib/kcadm-auth.sh
. "$(dirname "$0")/../_lib/kcadm-auth.sh"

NS=keycloak
APP_NS=app
KC_POD=keycloak-0
REALM=secforge-tenants

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Map client_id -> base URL
declare -A CLIENT_URLS=(
    [helloworld-bff]="https://app.secforge.local"
    [proposal-forge-bff]="https://pf.secforge.local"
    [project-tracker-bff]="https://pt.secforge.local"
    [pm-bff]="https://pm.secforge.local"
)

# 1. Sanity checks.
kubectl get ns "$APP_NS" >/dev/null
kubectl get pod -n "$NS" "$KC_POD" >/dev/null

# 2. Per-client keypair + K8s Secret.
declare -A PUBKEY_PEM
for client_id in "${!CLIENT_URLS[@]}"; do
    secret_name="bff-jwt-${client_id}"
    if kubectl get secret -n "$APP_NS" "$secret_name" >/dev/null 2>&1; then
        green "==> Secret app/${secret_name} exists; reusing existing keypair"
    else
        green "==> Generating fresh RSA-2048 keypair for ${client_id}"
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' RETURN
        openssl genrsa -out "$tmpdir/private.pem" 2048 2>/dev/null
        openssl rsa  -in  "$tmpdir/private.pem" -pubout \
                     -out "$tmpdir/public.pem" 2>/dev/null
        kubectl create secret generic "$secret_name" \
            --namespace "$APP_NS" \
            --from-file=private.pem="$tmpdir/private.pem" \
            --from-file=public.pem="$tmpdir/public.pem"
        kubectl label secret "$secret_name" -n "$APP_NS" \
            app.kubernetes.io/name=bff \
            secforge.platform/component=bff \
            secforge.platform/client-id="$client_id" \
            secforge.platform/key-purpose=client-jwt-signing \
            --overwrite
        rm -rf "$tmpdir"
        trap - RETURN
    fi
    # Strip PEM headers/footers and join into a single base64 string —
    # Keycloak's `jwt.credential.public.key` attribute wants exactly that.
    pem_body=$(kubectl get secret -n "$APP_NS" "$secret_name" \
        -o jsonpath='{.data.public\.pem}' | base64 -d \
        | sed -e '/^-----BEGIN/d' -e '/^-----END/d' | tr -d '\n')
    PUBKEY_PEM[$client_id]=$pem_body
done

# 3. Authenticate kcadm as kcadm-admin (per ADR-0022).
#    kcadm.sh writes its session to ~/.keycloak/kcadm.config by default.
#    Container HOME is /opt/keycloak; readOnlyRootFilesystem is disabled
#    on this container (see 04-keycloak-cr.yaml comment), so the default
#    location works.
green "==> Authenticating kcadm.sh in pod ${KC_POD} as kcadm-admin"
kcadm_admin_auth || exit 1

kcadm() {
    kubectl exec -n "$NS" "$KC_POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# 4. For each client, create-or-update.
for client_id in "${!CLIENT_URLS[@]}"; do
    base="${CLIENT_URLS[$client_id]}"
    pubkey="${PUBKEY_PEM[$client_id]}"

    green "==> Reconciling client ${client_id} in realm ${REALM} (base=${base})"

    # Build client representation. Keycloak accepts JSON via -f.
    #
    # Notes on the attribute names (these come from Keycloak's source):
    #   - require.pushed.authorization.requests   → enforce PAR
    #   - dpop.bound.access.tokens                → require DPoP, bind to cnf.jkt
    #   - pkce.code.challenge.method=S256         → enforce PKCE S256
    #   - use.jwks.url=false + jwt.credential.public.key → static pubkey
    #   - token.endpoint.auth.signing.alg=PS256   → BFF signs assertion w/ PS256
    #   - id.token.signed.response.alg=RS256
    #   - access.token.signed.response.alg=RS256
    #   - userinfo.signed.response.alg=RS256
    client_json=$(cat <<EOF
{
  "clientId": "${client_id}",
  "name": "${client_id}",
  "description": "BFF for ${client_id}; private_key_jwt (PS256), PAR+PKCE+DPoP required.",
  "enabled": true,
  "alwaysDisplayInConsole": false,
  "clientAuthenticatorType": "client-jwt",
  "redirectUris": ["${base}/auth/callback"],
  "webOrigins": ["${base}"],
  "rootUrl": "${base}",
  "baseUrl": "${base}",
  "adminUrl": "",
  "notBefore": 0,
  "bearerOnly": false,
  "consentRequired": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "publicClient": false,
  "frontchannelLogout": true,
  "protocol": "openid-connect",
  "fullScopeAllowed": false,
  "nodeReRegistrationTimeout": -1,
  "defaultClientScopes": ["web-origins", "acr", "profile", "roles", "email"],
  "optionalClientScopes": ["offline_access", "address", "phone", "microprofile-jwt"],
  "attributes": {
    "post.logout.redirect.uris": "${base}",
    "oauth2.device.authorization.grant.enabled": "false",
    "oidc.ciba.grant.enabled": "false",
    "backchannel.logout.session.required": "true",
    "backchannel.logout.revoke.offline.tokens": "false",
    "use.refresh.tokens": "true",
    "client_credentials.use_refresh_token": "false",
    "exclude.session.state.from.auth.response": "false",
    "tls.client.certificate.bound.access.tokens": "false",
    "dpop.bound.access.tokens": "true",
    "require.pushed.authorization.requests": "true",
    "pkce.code.challenge.method": "S256",
    "use.jwks.url": "false",
    "use.jwks.string": "false",
    "jwt.credential.public.key": "${pubkey}",
    "token.endpoint.auth.signing.alg": "PS256",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "userinfo.signed.response.alg": "RS256",
    "request.object.signature.alg": "PS256",
    "access.token.lifespan": "300",
    "access.token.header.type.rfc9068": "true"
  }
}
EOF
)

    # Push JSON into the pod under /tmp for kcadm -f.
    kubectl exec -i -n "$NS" "$KC_POD" -c keycloak -- \
        sh -c "cat > /tmp/kcadm-client-${client_id}.json" <<<"$client_json"

    # Lookup existing client (by clientId, not the internal id).
    # csv --noquotes emits the bare value on one line, no header.
    existing_id=$(kcadm get clients -r "$REALM" \
        -q "clientId=${client_id}" --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true)

    if [ -n "$existing_id" ]; then
        yellow "    exists (id=${existing_id}); updating"
        kcadm update "clients/${existing_id}" -r "$REALM" \
            -f "/tmp/kcadm-client-${client_id}.json"
    else
        green "    creating"
        kcadm create clients -r "$REALM" \
            -f "/tmp/kcadm-client-${client_id}.json"
    fi
done

green ""
green "All four BFF clients reconciled in realm ${REALM}."
green "Per-client signing keys live in app/bff-jwt-* Secrets (Phase 5 migrates to OpenBao)."
