#!/usr/bin/env bash
# verify-q3-refresh.sh — live Q3 verification against running Keycloak.
#
# What this script tests
# ----------------------
# Whether Keycloak honors `scope=<existing> <new-audience>` on a refresh
# request such that the resulting access_token's `aud` claim contains the
# new audience. This is the Q3 outcome question from ADR-0012 § Resolution.
#
# Outcomes the library handles (`apps/lib/api-auth`):
#   (a) Keycloak grants — new aud appears in token's aud claim →
#       Client.MintTokenForAudience returns the new token.
#   (b) Keycloak rejects — refresh returns 4xx (invalid_scope etc.) →
#       Client.MintTokenForAudience returns ErrAudienceUnavailable.
#       BFF translates to 401 + clear-session + Location: /login.
#
# Library is correct for BOTH outcomes. This script just confirms which one
# Keycloak 26.3.3 actually exhibits today, so the addendum to ADR-0014
# records ground truth.
#
# Prerequisites
# -------------
# 1. F-CLU-11 closed — operator can write to Keycloak via kcadm Path A
#    (service-account client tagged secforge.local/temporary=yes).
# 2. A user session with a still-valid refresh_token. Either:
#    - jason.upole logs in via the BFF and copies the refresh_token from
#      Valkey (`kubectl exec -n valkey valkey-0 -- redis-cli -a $PASS
#      KEYS '*' | head` → `GET <session-key>` → extract refresh_token)
#    - run `bao login -method=oidc role=admin` flow and copy from there
# 3. The BFF client's `private_key_jwt` PEM from OpenBao at
#    `secret/data/keycloak/clients/helloworld-bff`.
#
# Usage
# -----
#   REFRESH_TOKEN=eyJ... \
#   CLIENT_PRIVATE_KEY_PEM=/tmp/bff-priv.pem \
#   bash infrastructure/lib/api-auth/verify-q3-refresh.sh
#
# The script writes the verbatim curl request + response to
# /tmp/q3-result.txt. Append the relevant lines to ADR-0014 §
# "Observed Q3 behavior".
set -euo pipefail

: "${REFRESH_TOKEN:?REFRESH_TOKEN env var required (see Prerequisites)}"
: "${CLIENT_PRIVATE_KEY_PEM:?path to BFF's private_key_jwt PEM required}"

KEYCLOAK_BASE="${KEYCLOAK_BASE:-https://auth.secforge.local}"
REALM="${REALM:-secforge-tenants}"
CLIENT_ID="${CLIENT_ID:-helloworld-bff}"
NEW_AUDIENCE="${NEW_AUDIENCE:-authzen-facade}"

TOKEN_ENDPOINT="${KEYCLOAK_BASE}/realms/${REALM}/protocol/openid-connect/token"
echo "Token endpoint: ${TOKEN_ENDPOINT}"
echo "Client:         ${CLIENT_ID}"
echo "New audience:   ${NEW_AUDIENCE}"
echo

# Build a private_key_jwt client_assertion (same shape Client.makeClientAssertion produces).
NOW=$(date +%s)
EXP=$((NOW + 60))
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
PAYLOAD=$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%d,"exp":%d,"jti":"q3-verify-%s"}' \
  "$CLIENT_ID" "$CLIENT_ID" "$TOKEN_ENDPOINT" "$NOW" "$EXP" "$(uuidgen 2>/dev/null || date +%s%N)")
PAYLOAD_B64=$(printf '%s' "$PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '=')
SIGINPUT="${HEADER}.${PAYLOAD_B64}"
SIG=$(printf '%s' "$SIGINPUT" | openssl dgst -sha256 -sign "$CLIENT_PRIVATE_KEY_PEM" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')
ASSERTION="${SIGINPUT}.${SIG}"

echo "=== Refresh attempt (scope expanded with ${NEW_AUDIENCE}) ==="
RESULT=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_assertion=${ASSERTION}" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "scope=openid profile email ${NEW_AUDIENCE}" \
  -w "\nHTTP_STATUS=%{http_code}\n")

echo "$RESULT" | tee /tmp/q3-result.txt

echo
echo "=== Decoded aud claim of new access_token (if successful) ==="
ACCESS_TOKEN=$(echo "$RESULT" | head -n -1 | jq -r '.access_token // empty' 2>/dev/null || true)
if [ -n "${ACCESS_TOKEN}" ]; then
  PAYLOAD_PART=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
  # base64url-decode (pad with =)
  PADDED="${PAYLOAD_PART}$(printf '=%.0s' $(seq 1 $((4 - ${#PAYLOAD_PART} % 4))))"
  echo "$PADDED" | tr '_-' '/+' | base64 -d 2>/dev/null | jq '.aud, .iss, .scope' || echo "(could not decode payload)"
fi

echo
echo "=== Outcome guidance ==="
echo "  - If the new access_token's aud claim contains '${NEW_AUDIENCE}'     → Q3 outcome (a)"
echo "  - If HTTP 4xx with error=invalid_scope or invalid_grant              → Q3 outcome (b)"
echo "  - Append the verbatim result to docs/02-decisions/0014-... addendum."
