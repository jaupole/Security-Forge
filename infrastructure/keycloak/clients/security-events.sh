#!/usr/bin/env bash
# Phase 6b-2 (post-closeout) — Idempotent provisioner for the two
# security-events Keycloak clients in the `secforge-tenants` realm.
#
# Why this script exists:
#   Phase 6b-2 commit 4 (41e27d1) shipped apps/security-events-collector/
#   deploy manifests + Kyverno policies + the verify suite, but the
#   Keycloak-side provisioning for security-events-collector +
#   security-events-ci was missing. apps/lib/api-auth/'s middleware
#   requires both clients to exist as audiences before the LIVE-mode
#   verify probes (and the real Phase 7 ingestion path) can pass.
#
# What this creates / ensures (all idempotent):
#
#   security-events-collector  (bearer-only, audience-target)
#     - Confidential client used as the *target audience* for all
#       security-events ingestion. apps/lib/api-auth/middleware.go
#       rejects tokens whose `aud` claim does not contain this
#       clientId — see audContains() in middleware.go.
#     - bearerOnly:true → can't initiate flows, only validates inbound
#       bearer tokens. publicClient:false + clientAuthenticatorType:
#       client-secret keep the "confidential" shape per ADR-0013 even
#       though the secret is never used to mint tokens (the receiver
#       validates someone else's token; it does not produce its own).
#     - serviceAccountsEnabled:false — collector has no outbound
#       credential needs (README § "What this service explicitly
#       does NOT do"). If a future ingestor needs outbound auth, that
#       capability lives on a separate client, not here.
#
#   security-events-ci          (client_credentials issuer)
#     - Confidential client for out-of-cluster CI runners. CI auths
#       with client_id/client_secret, gets back a short-lived JWT,
#       and POSTs it to the collector's webhook endpoint as Bearer.
#     - serviceAccountsEnabled:true with all interactive flows OFF
#       (standard/implicit/direct-access/device all false). Only the
#       client_credentials grant is allowed.
#     - Hardcoded-audience protocol mapper attached to the client
#       injects `security-events-collector` into the `aud` claim of
#       every issued access token. The collector's middleware then
#       sees aud=[security-events-ci, security-events-collector] and
#       passes the audContains check.
#
# Auth path (per ADR-0022): set BAO_TOKEN to an OpenBao token with
# read on secret/data/keycloak/clients/kcadm-admin. _lib/kcadm-auth.sh
# fetches the secret and authenticates kcadm as kcadm-admin in master.
#
# Usage:
#   BAO_TOKEN=$(cat ~/.bao-token) bash infrastructure/keycloak/clients/security-events.sh
#
# Output:
#   Prints the security-events-ci client_secret once on first creation
#   (or after a Keycloak-side rotation that wiped it). The collector
#   itself has no consumed secret — its role is audience-validation
#   only, so its secret is generated for completeness and not surfaced.

set -euo pipefail

# shellcheck source=../_lib/kcadm-auth.sh
. "$(dirname "$0")/../_lib/kcadm-auth.sh"

NS=keycloak
POD=keycloak-0
REALM=secforge-tenants
COLLECTOR_CLIENT_ID=security-events-collector
CI_CLIENT_ID=security-events-ci
AUDIENCE_MAPPER_NAME=audience-security-events-collector

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

kcadm() {
    kubectl exec -n "$NS" "$POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# Echo a client's internal id (Keycloak UUID) for $1=clientId in $REALM,
# or empty if absent.
client_internal_id() {
    kcadm get clients -r "$REALM" -q "clientId=$1" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true
}

# Stage a JSON file inside the keycloak-0 pod for `kcadm -f /tmp/<name>`.
# kcadm requires the file to be inside the pod; piping via stdin is not
# supported for object create/update.
stage_json_in_pod() {
    local path="$1" body="$2"
    kubectl exec -i -n "$NS" "$POD" -c keycloak -- \
        sh -c "cat > $path" <<<"$body"
}

# ─── 1. Authenticate as kcadm-admin (ADR-0022) ──────────────────────
green "==> kcadm config credentials --client kcadm-admin (master realm)"
kcadm_admin_auth || exit 1
green "    auth ok"

# ─── 2. security-events-collector (audience target, bearer-only) ────
green "==> ensure $COLLECTOR_CLIENT_ID client in $REALM realm"

COLLECTOR_JSON='{
  "clientId": "security-events-collector",
  "name": "Security Events Collector",
  "description": "Audience target for secrets.guardrail.bypass events. Validated by apps/lib/api-auth/ middleware (aud claim). Phase 6b-2.",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "bearerOnly": true,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "attributes": {
    "oauth2.device.authorization.grant.enabled": "false",
    "oidc.ciba.grant.enabled": "false",
    "use.refresh.tokens": "false",
    "client_credentials.use_refresh_token": "false",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "userinfo.signed.response.alg": "RS256"
  }
}'

stage_json_in_pod /tmp/security-events-collector.json "$COLLECTOR_JSON"

EXISTING=$(client_internal_id "$COLLECTOR_CLIENT_ID")
if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/security-events-collector.json
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/security-events-collector.json
fi

# ─── 3. security-events-ci (client_credentials issuer) ──────────────
green "==> ensure $CI_CLIENT_ID client in $REALM realm"

CI_JSON='{
  "clientId": "security-events-ci",
  "name": "Security Events CI",
  "description": "Out-of-cluster CI runner identity for posting secrets.guardrail.bypass events. client_credentials only. Phase 6b-2.",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "bearerOnly": false,
  "clientAuthenticatorType": "client-secret",
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "attributes": {
    "oauth2.device.authorization.grant.enabled": "false",
    "oidc.ciba.grant.enabled": "false",
    "use.refresh.tokens": "false",
    "client_credentials.use_refresh_token": "false",
    "access.token.lifespan": "300",
    "id.token.signed.response.alg": "RS256",
    "access.token.signed.response.alg": "RS256",
    "userinfo.signed.response.alg": "RS256",
    "access.token.header.type.rfc9068": "true"
  },
  "defaultClientScopes": ["roles", "web-origins", "acr"],
  "optionalClientScopes": []
}'

stage_json_in_pod /tmp/security-events-ci.json "$CI_JSON"

EXISTING=$(client_internal_id "$CI_CLIENT_ID")
CI_CLIENT_NEWLY_CREATED=0
if [ -n "$EXISTING" ]; then
    yellow "    already present (id=$EXISTING); updating"
    kcadm update "clients/$EXISTING" -r "$REALM" -f /tmp/security-events-ci.json
    CI_INTERNAL_ID="$EXISTING"
else
    green "    creating"
    kcadm create clients -r "$REALM" -f /tmp/security-events-ci.json
    CI_INTERNAL_ID=$(client_internal_id "$CI_CLIENT_ID")
    CI_CLIENT_NEWLY_CREATED=1
fi

# ─── 4. Hardcoded audience mapper on security-events-ci ─────────────
# Attach an oidc-audience-mapper named $AUDIENCE_MAPPER_NAME that
# injects security-events-collector into the aud claim of every token
# issued FOR security-events-ci. Without this, tokens minted via
# client_credentials carry aud=[security-events-ci, account] and the
# collector's middleware audContains check fails.
#
# Idempotent: kcadm has no native upsert for protocol mappers, so we
# probe by name. If absent → create. If present → update via the
# returned id.
green "==> ensure audience mapper '$AUDIENCE_MAPPER_NAME' on $CI_CLIENT_ID"

MAPPER_JSON='{
  "name": "audience-security-events-collector",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "consentRequired": false,
  "config": {
    "included.client.audience": "security-events-collector",
    "included.custom.audience": "",
    "id.token.claim": "false",
    "access.token.claim": "true",
    "introspection.token.claim": "true",
    "lightweight.claim": "false"
  }
}'
stage_json_in_pod /tmp/security-events-ci-aud-mapper.json "$MAPPER_JSON"

# Look up an existing mapper by name on this client. kcadm's
# protocol-mappers/models endpoint lists all mappers; jq filters by
# name. (jq is in the keycloak image — confirmed by the parallel grep
# in grafana.sh's secret extraction.)
MAPPER_ID=$(kcadm get "clients/$CI_INTERNAL_ID/protocol-mappers/models" \
    -r "$REALM" 2>/dev/null \
    | jq -r ".[] | select(.name == \"$AUDIENCE_MAPPER_NAME\") | .id" \
    | head -1)

if [ -n "$MAPPER_ID" ]; then
    yellow "    already present (id=$MAPPER_ID); updating"
    # PUT to a specific mapper requires the id field set in the body.
    UPDATE_JSON=$(printf '%s' "$MAPPER_JSON" | jq --arg id "$MAPPER_ID" '. + {id: $id}')
    stage_json_in_pod /tmp/security-events-ci-aud-mapper-update.json "$UPDATE_JSON"
    kcadm update "clients/$CI_INTERNAL_ID/protocol-mappers/models/$MAPPER_ID" \
        -r "$REALM" -f /tmp/security-events-ci-aud-mapper-update.json
else
    green "    creating"
    kcadm create "clients/$CI_INTERNAL_ID/protocol-mappers/models" \
        -r "$REALM" -f /tmp/security-events-ci-aud-mapper.json
fi

# ─── 5. security-events-ci client_secret ────────────────────────────
# Print logic: surface the secret on first creation (Keycloak auto-mints
# one when a confidential client is created — we did not generate it,
# but the operator still needs it to stage into wherever CI runners
# fetch credentials). On re-runs, the existing secret stays in Keycloak
# and is not re-printed; if you need to recover it, re-fetch via
# `kcadm get clients/<id>/client-secret` directly.
green "==> $CI_CLIENT_ID client_secret"
CI_SECRET_JSON=$(kcadm get "clients/$CI_INTERNAL_ID/client-secret" -r "$REALM" 2>/dev/null || true)
CI_SECRET=$(jq -r '.value // empty' <<<"$CI_SECRET_JSON")
if [ -z "$CI_SECRET" ]; then
    yellow "    no secret yet — regenerating"
    CI_SECRET_JSON=$(kcadm create "clients/$CI_INTERNAL_ID/client-secret" -r "$REALM" -i 2>&1 | tail -1)
    CI_SECRET=$(jq -r '.value // empty' <<<"$CI_SECRET_JSON")
fi

# ─── 6. Output ──────────────────────────────────────────────────────
green ""
green "security-events-collector: provisioned in $REALM (bearer-only, aud target)."
green "security-events-ci:        provisioned in $REALM (client_credentials)."
green "  audience mapper:         injects 'security-events-collector' into aud claim."

if [ "$CI_CLIENT_NEWLY_CREATED" = "1" ]; then
    yellow ""
    yellow "═════════════════════════════════════════════════════════════════════"
    yellow " security-events-ci client_secret (capture now — printed once):"
    yellow ""
    yellow "   $CI_SECRET"
    yellow ""
    yellow " Stage into OpenBao for CI runner consumption:"
    yellow ""
    yellow "   kubectl exec -n openbao openbao-0 -c openbao -- \\"
    yellow "       env BAO_SKIP_VERIFY=1 BAO_TOKEN=\"\$BAO_TOKEN\" \\"
    yellow "       bao kv put secret/keycloak/clients/security-events-ci \\"
    yellow "           client_secret='$CI_SECRET'"
    yellow "═════════════════════════════════════════════════════════════════════"
else
    green "  ci secret:  unchanged (still in Keycloak; not re-printed)"
fi
