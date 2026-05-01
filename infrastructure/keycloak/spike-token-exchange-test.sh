#!/usr/bin/env bash
# Phase 6b-0 token-exchange spike — end-to-end test driver.
#
# Drives:
#   1. spike-bff authenticates with private_key_jwt → access token T1
#      (subject token; via client_credentials so no browser is involved)
#   2. spike-bff exchanges T1 for aud=spike-api → access token T2
#   3. Decode T2; print every claim; verify aud / sub / act / exp /
#      signing key match RFC 8693 expectations
#   4. Probe a few error cases the library will need to map:
#        - exchange for an unauthorized audience (expect invalid_client/access_denied)
#        - exchange with a bogus subject_token (expect invalid_token)
#
# Idempotent: re-running just re-issues fresh tokens. Reads the keypair
# from /tmp/secforge-spike/spike-bff-private.pem (left there by
# spike-token-exchange.sh).
#
# Usage:
#   bash infrastructure/keycloak/spike-token-exchange-test.sh
#
# Output:
#   * full token claims (T1 and T2) on stdout
#   * pass/fail line per assertion
#   * a "FINDINGS" block at the end summarizing what to write into
#     ADR-0012's deviations section

set -euo pipefail

REALM=secforge-tenants
ISSUER="https://auth.secforge.local/realms/${REALM}"
TOKEN_ENDPOINT="${ISSUER}/protocol/openid-connect/token"
JWKS_ENDPOINT="${ISSUER}/protocol/openid-connect/certs"
BFF_CLIENT=spike-bff
API_CLIENT=spike-api
SPIKE_DIR=/tmp/secforge-spike
KEY_FILE="$SPIKE_DIR/spike-bff-private.pem"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -f "$KEY_FILE" ] || { red "missing $KEY_FILE — run spike-token-exchange.sh first"; exit 1; }
command -v python3 >/dev/null || { red "python3 required"; exit 1; }
python3 -c 'import jwt' 2>/dev/null || { red "PyJWT required (pip3 install pyjwt cryptography)"; exit 1; }
python3 -c 'from cryptography.hazmat.primitives import serialization' 2>/dev/null || \
    { red "cryptography required"; exit 1; }

# ─── helpers ────────────────────────────────────────────────────────

# Generate a private_key_jwt assertion (RFC 7523) signed with PS256.
# Audience is the token endpoint URL — Keycloak validates that exactly.
make_client_assertion() {
    local client_id="$1"
    local key_path="$2"
    local audience="$3"
    python3 - "$client_id" "$key_path" "$audience" <<'PY'
import sys, time, uuid, jwt
client_id, key_path, audience = sys.argv[1:4]
with open(key_path, 'rb') as f:
    key = f.read()
now = int(time.time())
payload = {
    "iss": client_id,
    "sub": client_id,
    "aud": audience,
    "iat": now,
    "exp": now + 60,
    "jti": str(uuid.uuid4()),
}
print(jwt.encode(payload, key, algorithm="PS256"), end="")
PY
}

# Decode any JWT to a single-line JSON {header, payload}. No verification.
decode_jwt_unsafe() {
    python3 - "$1" <<'PY'
import sys, json, base64
def b64d(s):
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())
parts = sys.argv[1].split(".")
header = json.loads(b64d(parts[0]))
payload = json.loads(b64d(parts[1]))
print(json.dumps({"header": header, "payload": payload}, indent=2))
PY
}

# Verify a JWT's signature against the realm JWKS, and return decoded payload.
verify_jwt() {
    local token="$1"
    local jwks
    jwks=$(curl -fsS "$JWKS_ENDPOINT")
    python3 - "$token" "$jwks" "$ISSUER" <<'PY'
import sys, json, jwt
from jwt import PyJWKClient, PyJWK
token, jwks_raw, issuer = sys.argv[1:4]
jwks = json.loads(jwks_raw)
header = jwt.get_unverified_header(token)
kid = header["kid"]
matched = next((k for k in jwks["keys"] if k["kid"] == kid), None)
if matched is None:
    print(f"FAIL: kid {kid} not in JWKS", file=sys.stderr); sys.exit(1)
key = PyJWK(matched).key
claims = jwt.decode(
    token, key=key,
    algorithms=[matched.get("alg", header.get("alg", "RS256"))],
    audience=None,             # we'll check aud manually
    options={"verify_aud": False, "verify_signature": True, "verify_exp": True},
)
print("OK")
PY
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        green "  PASS  $label  ($actual)"
    else
        red   "  FAIL  $label  expected=$expected actual=$actual"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        green "  PASS  $label contains '$needle'"
    else
        red   "  FAIL  $label missing '$needle'  (haystack: $haystack)"
    fi
}

# ─── 1. Get subject token via client_credentials ────────────────────
green "==> 1. Mint subject token (client_credentials with private_key_jwt)"
ASSERTION=$(make_client_assertion "$BFF_CLIENT" "$KEY_FILE" "$TOKEN_ENDPOINT")
T1_RESPONSE=$(curl -sS "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=$BFF_CLIENT" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$ASSERTION")
T1=$(jq -r '.access_token // empty' <<<"$T1_RESPONSE")
if [ -z "$T1" ]; then
    red "    failed to mint subject token; raw response:"
    jq . <<<"$T1_RESPONSE" >&2 || echo "$T1_RESPONSE" >&2
    exit 1
fi
green "    got T1 (length ${#T1})"
echo "    T1 claims:"
decode_jwt_unsafe "$T1" | sed 's/^/      /'

# ─── 2. Exchange T1 for aud=spike-api ───────────────────────────────
green "==> 2. token-exchange T1 → aud=$API_CLIENT"
ASSERTION=$(make_client_assertion "$BFF_CLIENT" "$KEY_FILE" "$TOKEN_ENDPOINT")
T2_RESPONSE=$(curl -sS "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=$BFF_CLIENT" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$ASSERTION" \
    -d "subject_token=$T1" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "audience=$API_CLIENT" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")
echo "    raw response (top-level keys only):"
jq -r 'keys | "      " + (. | tostring)' <<<"$T2_RESPONSE" 2>&1 || echo "      <not JSON> $T2_RESPONSE"
T2=$(jq -r '.access_token // empty' <<<"$T2_RESPONSE")
if [ -z "$T2" ]; then
    red "    exchange failed; raw response:"
    jq . <<<"$T2_RESPONSE" >&2 || echo "$T2_RESPONSE" >&2
    yellow ""
    yellow "Common causes:"
    yellow "  - 'unsupported_grant_type': feature flag missing on the realm"
    yellow "  - 'invalid_target' / 'access_denied': fine-grained perm not attached"
    yellow "  - 'invalid_client': private_key_jwt assertion rejected (clock skew? wrong aud?)"
    exit 1
fi
green "    got T2 (length ${#T2})"
echo ""
echo "    Full token-exchange response body:"
jq . <<<"$T2_RESPONSE" | sed 's/^/      /'
echo ""
echo "    T2 claims:"
T2_DECODED=$(decode_jwt_unsafe "$T2")
echo "$T2_DECODED" | sed 's/^/      /'

# ─── 3. Verify signature ────────────────────────────────────────────
green "==> 3. verify T2 signature against realm JWKS"
verify_jwt "$T2" | sed 's/^/    /'

# ─── 4. Assertions on T2 claims ─────────────────────────────────────
green "==> 4. assertions on T2 claims (RFC 8693 expectations)"
T2_PAYLOAD=$(echo "$T2_DECODED" | jq '.payload')
T1_PAYLOAD=$(decode_jwt_unsafe "$T1" | jq '.payload')

T1_SUB=$(jq -r '.sub' <<<"$T1_PAYLOAD")
T2_SUB=$(jq -r '.sub' <<<"$T2_PAYLOAD")
T2_AUD=$(jq -c '.aud' <<<"$T2_PAYLOAD")
T2_AZP=$(jq -r '.azp // "<absent>"' <<<"$T2_PAYLOAD")
T2_ACT=$(jq -c '.act // "<absent>"' <<<"$T2_PAYLOAD")
T2_EXP=$(jq -r '.exp' <<<"$T2_PAYLOAD")
T2_IAT=$(jq -r '.iat' <<<"$T2_PAYLOAD")
T2_TYP=$(jq -r '.header.typ' <<<"$(echo "$T2_DECODED" | jq '.')")
T2_KID=$(jq -r '.header.kid' <<<"$(echo "$T2_DECODED" | jq '.')")
T2_LIFESPAN=$(( T2_EXP - T2_IAT ))

assert_eq         "sub preserved"            "$T2_SUB"            "$T1_SUB"
assert_contains   "aud contains spike-api"   "$T2_AUD"            "spike-api"
case "$T2_AUD" in
    *"$BFF_CLIENT"*)  red   "  FAIL  aud should NOT contain $BFF_CLIENT (token-exchange should rewrite audience)" ;;
    *)                green "  PASS  aud does not contain $BFF_CLIENT" ;;
esac
case "$T2_ACT" in
    *"<absent>"*)
        yellow "  WARN  act claim absent — Keycloak v1 token-exchange historically omits this"
        yellow "        record this in ADR-0012 as a deviation: the audit chain must be"
        yellow "        carried separately (e.g., a custom mapper) or accepted as a gap" ;;
    *)
        green "  INFO  act present: $T2_ACT"
        ACT_SUB=$(jq -r '.sub' <<<"$T2_ACT")
        assert_eq "act.sub == spike-bff" "$ACT_SUB" "$BFF_CLIENT" ;;
esac
if [ "$T2_LIFESPAN" -le 600 ] && [ "$T2_LIFESPAN" -gt 0 ]; then
    green "  PASS  exp lifespan reasonable (${T2_LIFESPAN}s ≤ 600s)"
else
    red   "  FAIL  exp lifespan out of band (${T2_LIFESPAN}s)"
fi
assert_eq         "header.typ"               "$T2_TYP"            "at+jwt"

# ─── 5. Probe error cases ───────────────────────────────────────────
green "==> 5. error-case probes"

echo "    5a. exchange to an audience this client is NOT permitted for"
ASSERTION=$(make_client_assertion "$BFF_CLIENT" "$KEY_FILE" "$TOKEN_ENDPOINT")
ERR_RESPONSE=$(curl -sS "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=$BFF_CLIENT" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$ASSERTION" \
    -d "subject_token=$T1" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "audience=this-client-does-not-exist" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")
echo "    response: $(jq -c . <<<"$ERR_RESPONSE" 2>/dev/null || echo "$ERR_RESPONSE")"

echo "    5b. exchange with a malformed subject_token"
ASSERTION=$(make_client_assertion "$BFF_CLIENT" "$KEY_FILE" "$TOKEN_ENDPOINT")
ERR_RESPONSE=$(curl -sS "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=$BFF_CLIENT" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$ASSERTION" \
    -d "subject_token=not.a.jwt" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "audience=$API_CLIENT" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")
echo "    response: $(jq -c . <<<"$ERR_RESPONSE" 2>/dev/null || echo "$ERR_RESPONSE")"

echo "    5c. exchange WITHOUT requested_token_type (does Keycloak infer it?)"
ASSERTION=$(make_client_assertion "$BFF_CLIENT" "$KEY_FILE" "$TOKEN_ENDPOINT")
ERR_RESPONSE=$(curl -sS "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=$BFF_CLIENT" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$ASSERTION" \
    -d "subject_token=$T1" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "audience=$API_CLIENT")
echo "    response: $(jq -c . <<<"$ERR_RESPONSE" 2>/dev/null | head -c 200) ..."
echo "    .access_token present: $(jq -r 'has("access_token")' <<<"$ERR_RESPONSE" 2>/dev/null)"

# ─── Summary ────────────────────────────────────────────────────────
yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " FINDINGS to record in ADR-0012:"
yellow ""
yellow "   - request shape:    application/x-www-form-urlencoded, see step 2"
yellow "   - response shape:   see 'Full token-exchange response body' above"
yellow "   - sub preserved:    $T2_SUB (was $T1_SUB)"
yellow "   - aud:              $T2_AUD"
yellow "   - act:              $T2_ACT"
yellow "   - exp lifespan:     ${T2_LIFESPAN}s"
yellow "   - typ header:       $T2_TYP"
yellow "   - kid:              $T2_KID"
yellow "   - error mapping:    see step 5"
yellow "   - requested_token_type omitted → see step 5c"
yellow "═════════════════════════════════════════════════════════════════════"
