#!/usr/bin/env bash
# Phase 7d.1.b — CronJob entrypoint for the BFF key rotator.
#
# Reads the JWT-SVID written by spiffe-helper, exchanges via OpenBao
# auth/jwt/login (role bff-key-rotator) for a short-lived BAO_TOKEN,
# exports it, and execs rotate-bff-key.sh against the BFF named in
# BFF_CLIENT_ID.
#
# Required env (set by the CronJob spec):
#   BFF_CLIENT_ID      target client ID (one of the four BFFs)
#   KCADM_AUTH_HELPER  path to the in-pod kcadm-auth.sh (override for
#                      rotate-bff-key.sh's relative-path source)
#   BAO_ADDR           OpenBao URL (e.g. https://openbao.openbao.svc:8200)
#   BAO_JWT_PATH       path to the JWT-SVID file (e.g. /shared/openbao.jwt)
#   BAO_ROLE           OpenBao auth/jwt role name (bff-key-rotator)

set -euo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log_err() {
    printf '{"ts":"%s","severity":"error","event":"bff.key.rotation.failed","step":"wrapper","msg":"%s"}\n' \
        "$(ts)" "$1" >&2
}

: "${BFF_CLIENT_ID:?BFF_CLIENT_ID env required}"
: "${KCADM_AUTH_HELPER:?KCADM_AUTH_HELPER env required}"
: "${BAO_ADDR:?BAO_ADDR env required}"
: "${BAO_JWT_PATH:?BAO_JWT_PATH env required}"
: "${BAO_ROLE:?BAO_ROLE env required}"

if [ ! -r "$BAO_JWT_PATH" ]; then
    log_err "JWT-SVID not readable at $BAO_JWT_PATH (spiffe-helper init container failed?)"
    exit 1
fi

JWT=$(cat "$BAO_JWT_PATH")
if [ -z "$JWT" ]; then
    log_err "JWT-SVID file is empty"
    exit 1
fi

# Mint OpenBao token via auth/jwt/login. -k tolerated locally because
# OpenBao's serving cert is mkcert-signed and alpine/k8s doesn't bundle
# our local CA. The risk this papers over (bogus OpenBao impersonation)
# is mitigated by NetworkPolicy + Istio Ambient L4 mTLS at the cluster
# boundary; cloud-edition migration MUST replace -k with a CA bundle
# mount once the trust domain is unified (Phase 7c → cloud).
LOGIN_BODY=$(printf '{"role":"%s","jwt":"%s"}' "$BAO_ROLE" "$JWT")
RESP=$(curl -ksS -X POST -H 'Content-Type: application/json' \
    -d "$LOGIN_BODY" "$BAO_ADDR/v1/auth/jwt/login" 2>&1)
TOKEN=$(printf '%s' "$RESP" | jq -r '.auth.client_token // empty')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    # Echo the response without the JWT (which is in $JWT, not the body)
    # so operators can debug auth failures without exposing the SVID.
    log_err "auth/jwt/login returned no client_token (role=$BAO_ROLE response=$RESP)"
    exit 1
fi

export BAO_TOKEN="$TOKEN"

printf '{"ts":"%s","severity":"info","event":"bff.key.rotation.step","step":"wrapper-auth-success","client_id":"%s"}\n' \
    "$(ts)" "$BFF_CLIENT_ID"

exec /bin/bash /scripts/rotate-bff-key.sh "$BFF_CLIENT_ID"
