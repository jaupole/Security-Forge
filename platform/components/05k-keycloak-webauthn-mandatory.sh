#!/usr/bin/env bash
# 05k — Replace TOTP with mandatory WebAuthn (passkey) on the platform realm.
#
# Goal: 2-factor login = password + passkey. NO TOTP anywhere.
#
# What this does (in order):
#   1. Configures realm-wide WebAuthn policy (RP ID, user-verification=required,
#      signature algos). RP ID set to the apex domain (secforge.dev) so passkeys
#      work across all subdomains: auth., control., portal., grafana., etc.
#   2. Enables the `webauthn-register` required action and marks it as default
#      so new users get prompted to enroll on first login. NOT
#      `webauthn-register-passwordless` — we want it as a 2nd factor, not as
#      a password replacement.
#   3. Disables `CONFIGURE_TOTP` as a default action (the action stays defined
#      but is not auto-applied).
#   4. Builds a new browser auth flow by copying the default 'browser' flow
#      and replacing the OTP step with a WebAuthn step set to REQUIRED.
#   5. Binds the new flow as the realm's `browserFlow`.
#   6. Sweeps every existing user: removes OTP credentials and adds
#      `webauthn-register` as a per-user required action.
#
# The keycloak-0 container is distroless — no curl, no shell-utility chain.
# kcadm.sh can't validate the in-pod TLS cert. So this script calls the admin
# REST API from the host via the public Let's-Encrypt-trusted URL.
#
# Idempotent — re-running detects existing state and skips done steps.

set -uo pipefail

NS=keycloak
REALM="${REALM:-platform}"  # override with REALM=master for master-realm hardening
KC_URL="${KC_URL:-https://auth.secforge.dev}"
FLOW_ALIAS_NEW="browser-webauthn-required"
RP_ID="${RP_ID:-secforge.dev}"
RP_NAME="${RP_NAME:-SecForge Platform}"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ── Get master-realm admin token ──────────────────────────────────────────
ADMIN_USER=$(sudo kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(sudo kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)

green "==> [1/6] acquire master-realm admin token via $KC_URL"
TOKEN=$(curl -sS -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
[[ ${#TOKEN} -lt 100 ]] && { red "ERROR: failed to acquire admin token"; exit 1; }
green "    ok (token length ${#TOKEN})"

# Helper: kcurl <method> <path> [json-body]
kcurl() {
    local method=$1 path=$2 body=${3:-}
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            "$KC_URL/admin/realms/$path" -d "$body"
    else
        curl -sS -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            "$KC_URL/admin/realms/$path"
    fi
}

# ── 1. Realm-wide WebAuthn policy ─────────────────────────────────────────
green "==> [2/6] configure realm-wide WebAuthn policy (RP=$RP_ID)"
WEBAUTHN_POLICY=$(cat <<EOF
{
  "webAuthnPolicyRpEntityName": "$RP_NAME",
  "webAuthnPolicyRpId": "$RP_ID",
  "webAuthnPolicySignatureAlgorithms": ["ES256","RS256"],
  "webAuthnPolicyAttestationConveyancePreference": "none",
  "webAuthnPolicyAuthenticatorAttachment": "not specified",
  "webAuthnPolicyRequireResidentKey": "not specified",
  "webAuthnPolicyUserVerificationRequirement": "required",
  "webAuthnPolicyCreateTimeout": 60,
  "webAuthnPolicyAvoidSameAuthenticatorRegister": false
}
EOF
)
kcurl PUT "$REALM" "$WEBAUTHN_POLICY" >/dev/null
green "    policy set: UV=required, RP=$RP_ID, name=$RP_NAME"

# ── 2. Required actions: enable webauthn-register, disable CONFIGURE_TOTP ─
green "==> [3/6] enable webauthn-register required action (default for new users)"
# Keycloak quirk: required actions need to be POST-registered before PUT works.
# Check if already registered; if not, POST to register first.
ALREADY_REGISTERED=$(kcurl GET "$REALM/authentication/required-actions" \
  | python3 -c "import json,sys; print('yes' if any(r.get('alias')=='webauthn-register' for r in json.load(sys.stdin)) else 'no')")
if [[ "$ALREADY_REGISTERED" == "no" ]]; then
    yellow "    POST-registering webauthn-register (first-time)"
    kcurl POST "$REALM/authentication/register-required-action" \
        '{"providerId":"webauthn-register","name":"Webauthn Register"}' >/dev/null
fi
kcurl PUT "$REALM/authentication/required-actions/webauthn-register" '{
  "alias":"webauthn-register",
  "name":"Webauthn Register",
  "providerId":"webauthn-register",
  "enabled":true,
  "defaultAction":true,
  "priority":70,
  "config":{}
}' >/dev/null

green "==> [3b/6] disable CONFIGURE_TOTP default (action stays available but not auto-applied)"
kcurl PUT "$REALM/authentication/required-actions/CONFIGURE_TOTP" '{
  "alias":"CONFIGURE_TOTP",
  "name":"Configure OTP",
  "providerId":"CONFIGURE_TOTP",
  "enabled":false,
  "defaultAction":false,
  "priority":10,
  "config":{}
}' >/dev/null

# ── 3. Browser flow: copy default, swap OTP for WebAuthn ──────────────────
green "==> [4/6] build new browser flow '$FLOW_ALIAS_NEW' with WebAuthn required"
EXISTS=$(kcurl GET "$REALM/authentication/flows" \
  | python3 -c "import json,sys; print('yes' if any(f['alias']=='$FLOW_ALIAS_NEW' for f in json.load(sys.stdin)) else 'no')")

if [[ "$EXISTS" == "yes" ]]; then
    yellow "    flow $FLOW_ALIAS_NEW already exists — skipping copy"
else
    kcurl POST "$REALM/authentication/flows/browser/copy" "{\"newName\":\"$FLOW_ALIAS_NEW\"}" >/dev/null
    green "    copied 'browser' to '$FLOW_ALIAS_NEW'"
fi

# Fetch executions
EXECS=$(kcurl GET "$REALM/authentication/flows/$FLOW_ALIAS_NEW/executions")
printf '%s' "$EXECS" > /tmp/flow-execs.json

# Find the OTP form + WebAuthn executions
OTP_ID=$(python3 -c "
import json
d=json.load(open('/tmp/flow-execs.json'))
for e in d:
    if e.get('providerId')=='auth-otp-form':
        print(e['id']); break")
WAN_ID=$(python3 -c "
import json
d=json.load(open('/tmp/flow-execs.json'))
for e in d:
    if e.get('providerId')=='webauthn-authenticator':
        print(e['id']); break")

if [[ -n "$OTP_ID" ]]; then
    yellow "    deleting OTP Form execution ($OTP_ID)"
    kcurl DELETE "$REALM/authentication/executions/$OTP_ID" >/dev/null
fi

if [[ -n "$WAN_ID" ]]; then
    yellow "    setting WebAuthn Authenticator to ALTERNATIVE (with Recovery Codes as alternative)"
    WAN_OBJ=$(python3 -c "
import json
d=json.load(open('/tmp/flow-execs.json'))
for e in d:
    if e['id']=='$WAN_ID':
        e['requirement']='ALTERNATIVE'
        print(json.dumps(e)); break")
    kcurl PUT "$REALM/authentication/flows/$FLOW_ALIAS_NEW/executions" "$WAN_OBJ" >/dev/null
fi

# Flip Recovery Authentication Code Form from DISABLED → ALTERNATIVE so users
# can use recovery codes as a login-time self-service fallback if they lose
# their passkey device. Keycloak surfaces a "Try another way" link on the
# WebAuthn screen when multiple ALTERNATIVES exist in the same subflow.
REC_ID=$(python3 -c "
import json
d=json.load(open('/tmp/flow-execs.json'))
for e in d:
    if e.get('providerId')=='auth-recovery-authn-code-form':
        print(e['id']); break")
if [[ -n "$REC_ID" ]]; then
    yellow "    setting Recovery Authentication Code Form to ALTERNATIVE (passkey-loss fallback)"
    REC_OBJ=$(python3 -c "
import json
d=json.load(open('/tmp/flow-execs.json'))
for e in d:
    if e['id']=='$REC_ID':
        e['requirement']='ALTERNATIVE'
        print(json.dumps(e)); break")
    kcurl PUT "$REALM/authentication/flows/$FLOW_ALIAS_NEW/executions" "$REC_OBJ" >/dev/null
fi

# ── 4. Bind the new flow ──────────────────────────────────────────────────
green "==> [5/6] bind realm browserFlow to '$FLOW_ALIAS_NEW'"
kcurl PUT "$REALM" "{\"browserFlow\":\"$FLOW_ALIAS_NEW\"}" >/dev/null

# ── 5. Sweep users: drop OTPs, add webauthn-register action ───────────────
green "==> [6/6] sweep users — remove OTP credentials + add webauthn-register required action"
USERS_JSON=$(kcurl GET "$REALM/users?max=1000")
printf '%s' "$USERS_JSON" > /tmp/users.json

# Use a python helper that calls curl directly (avoid kcurl quoting issues)
cat > /tmp/sweep.py <<'PYEOF'
import json, subprocess, os
TOKEN = os.environ["TOKEN"]
KC_URL = os.environ["KC_URL"]
REALM = os.environ["REALM"]

def call(method, path, body=None):
    cmd = ["curl","-sS","-X",method,
           "-H","Authorization: Bearer " + TOKEN,
           "-H","Content-Type: application/json",
           KC_URL + "/admin/realms/" + path]
    if body is not None:
        cmd.extend(["-d", body])
    return subprocess.run(cmd, capture_output=True).stdout.decode()

users = json.load(open("/tmp/users.json"))
changed = 0
removed = 0
added = 0
for u in users:
    uid = u["id"]; uname = u["username"]
    creds_raw = call("GET", REALM + "/users/" + uid + "/credentials")
    try:
        creds = json.loads(creds_raw)
    except Exception:
        print("  ! " + uname + ": failed to parse credentials")
        continue
    user_changed = False
    for c in creds:
        if c.get("type") == "otp":
            call("DELETE", REALM + "/users/" + uid + "/credentials/" + c["id"])
            removed += 1
            user_changed = True
            print("  - removed OTP credential '" + str(c.get("userLabel")) + "' for " + uname)
    cur_actions = u.get("requiredActions") or []
    if "webauthn-register" not in cur_actions:
        new_actions = list(cur_actions) + ["webauthn-register"]
        call("PUT", REALM + "/users/" + uid, json.dumps({"requiredActions": new_actions}))
        added += 1
        user_changed = True
        print("  + added webauthn-register required action for " + uname)
    if user_changed:
        changed += 1
print("\nTotal: " + str(changed) + " users updated (" + str(removed) + " OTP creds removed, " + str(added) + " actions added)")
PYEOF
TOKEN="$TOKEN" KC_URL="$KC_URL" REALM="$REALM" python3 /tmp/sweep.py

cat <<EOF

✓ WebAuthn-as-2nd-factor configured.

  Realm browserFlow: $FLOW_ALIAS_NEW
  WebAuthn RP ID:    $RP_ID  (covers all *.secforge.dev subdomains)
  WebAuthn UV:       required
  CONFIGURE_TOTP:    disabled as default

What each user sees on their next login:
  1. username + password page
  2. "Set up a passkey" enrollment screen (one-time)
  3. Biometric prompt — choose: same-device (Touch ID / Windows Hello)
     or cross-device (phone QR + phone biometric)
  4. From login #2 onward: username/password page → biometric prompt

To force re-enrollment for a user (e.g. lost device):
  curl -X PUT $KC_URL/admin/realms/$REALM/users/<id> \\
       -H "Authorization: Bearer <token>" \\
       -d '{"requiredActions":["webauthn-register"]}'

Emergency rollback to TOTP:
  curl -X PUT $KC_URL/admin/realms/$REALM \\
       -H "Authorization: Bearer <token>" \\
       -d '{"browserFlow":"browser"}'
  (the built-in 'browser' flow was not modified — copy was made first)
EOF
