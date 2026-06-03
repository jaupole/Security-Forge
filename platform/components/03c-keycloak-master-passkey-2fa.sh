#!/usr/bin/env bash
# 03c — Keycloak `master` realm passkey-2FA flow replay (DB-write, idempotent)
#
# ─── Why this script exists ──────────────────────────────────────────────
#
# The `platform` and `secforge-tenants` realms are recreated declaratively
# from KeycloakRealmImport YAMLs
# (platform/manifests/keycloak/realms/{platform,secforge-tenants}-realm.yaml),
# and their day-2 / DR replay lives in 03a (kcadm) + 03b (DB-write).
#
# The `master` realm has NEITHER:
#   - It is the Keycloak bootstrap realm and is NOT realm-importable.
#   - 03a explicitly hardens only platform + secforge-tenants, and its
#     kcadm path cannot authenticate against master anyway: jaupole is the
#     sole master-realm admin and is WebAuthn-required, so no automated
#     kcadm session can be opened (project_keycloak_admin_db_only).
#
# Result: master's login posture (UN/PW first factor, passkey-preferred
# 2FA, recovery codes as break-glass) exists ONLY in the live DB. If the
# Keycloak DB is rebuilt or restored from a backup predating that manual
# setup, master comes back on Keycloak's stock `browser` flow — password
# only, no passkey, and (worse) it can resurface recovery codes ahead of
# the passkey. This script is the missing recovery path: it reproduces the
# posture from scratch via direct Postgres writes, exactly as 03b does for
# the tenants realm.
#
# ─── Target end-state (master realm only) ────────────────────────────────
#
# Browser flow `browser-webauthn-required` (top-level, built_in=false),
# bound as realm.browser_flow:
#
#   browser-webauthn-required
#   ├─ auth-cookie                    ALTERNATIVE  10
#   ├─ auth-spnego                    DISABLED     20
#   ├─ identity-provider-redirector   ALTERNATIVE  25
#   └─ (subflow) forms                ALTERNATIVE  30
#      ├─ auth-username-password-form REQUIRED     10   ← UN/PW first factor
#      └─ (subflow) Conditional 2FA   CONDITIONAL  20
#         ├─ conditional-user-configured  REQUIRED    10
#         ├─ webauthn-authenticator       ALTERNATIVE 30   ← passkey (default 2FA)
#         └─ auth-recovery-authn-code-form ALTERNATIVE 40  ← break-glass only
#
# THE INVARIANT THIS SCRIPT GUARANTEES: webauthn-authenticator is an
# ALTERNATIVE with a LOWER priority number than auth-recovery-authn-code-form,
# so Keycloak presents the passkey as the default second factor and recovery
# codes only via "Try another way". (Keycloak 26 selects the first
# alternative configured for the user; lower execution priority = first.)
#
# Required actions:
#   - webauthn-register                : enabled=true,  default_action=true
#                                        (master FORCES passkey enrolment)
#   - webauthn-register-passwordless    : enabled=true,  default_action=false
#                                        (registered if missing; opt-in)
#   - CONFIGURE_RECOVERY_AUTHN_CODES    : enabled=true,  default_action=false
#                                        (RETAINED — sole-admin break-glass)
#   - CONFIGURE_TOTP                    : enabled=false, default_action=false
#                                        (passkey-only 2FA; no OTP on master)
#
# WebAuthn (2FA) policy:
#   RpId=secforge.dev, RpEntityName="SecForge Platform",
#   UserVerification=required, SignatureAlgorithms=ES256,RS256,
#   CreateTimeout=60.
#
# ─── KEY DIFFERENCE vs 03b ───────────────────────────────────────────────
#
# 03b (tenants) DELETES recovery-authn-codes credentials and disables the
# recovery required action — tenants recover via email reset + help-desk.
# THIS SCRIPT DOES THE OPPOSITE: master keeps recovery codes as the only
# break-glass for the sole admin. It NEVER deletes a credential.
#
# ─── Modes ───────────────────────────────────────────────────────────────
#
#   ./03c-keycloak-master-passkey-2fa.sh            # apply (idempotent) + bounce
#   ./03c-keycloak-master-passkey-2fa.sh --no-bounce# apply, skip pod bounce
#   ./03c-keycloak-master-passkey-2fa.sh --check    # READ-ONLY verify, no writes
#
# --check exits 0 if the live master realm already matches the target
# posture, 2 if it drifted. Safe to run against the live admin realm at any
# time. APPLY rebinds realm.browser_flow and bounces keycloak-0 to flush the
# Infinispan flow cache (direct DB writes do not invalidate it).
#
# Exit codes:
#   0  in target state (--check) OR applied + verified (+ bounced) OK
#   1  pre-flight failure (db unreachable, realm missing, no kubectl)
#   2  verification mismatch
#
# RELATED:
#   - Sibling DB-write replay (tenants): 03b-keycloak-tenants-flexible-flow.sh
#   - kcadm hardening (platform + tenants): 03a-keycloak-realm-hardening.sh
#   - Runbook: docs/03-runbooks/keycloak-master-flow-replay.md
#
set -euo pipefail
IFS=$'\n\t'

KEYCLOAK_NS="keycloak"
DB_POD="secforge-keycloak-db-1"
KC_POD="keycloak-0"
REALM="master"
DOMAIN="${DOMAIN:-secforge.dev}"
RP_ENTITY_NAME="${RP_ENTITY_NAME:-SecForge Platform}"

MODE="apply"
BOUNCE_POD=1
for arg in "$@"; do
  case "$arg" in
    --check)     MODE="check"; BOUNCE_POD=0 ;;
    --no-bounce) BOUNCE_POD=0 ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: $0 [--check | --no-bounce]" >&2; exit 1 ;;
  esac
done

# ─── kubectl detection (plain, else sudo -n) ──────────────────────────────
# On secforge-prod the `ops` user has no usable plain kubeconfig; kubectl
# only works through sudo. In other contexts plain kubectl may work. Detect.
# KUBECTL is an array (not a string): the script sets IFS=$'\n\t', which strips
# space from word-splitting, so a multi-word string value like "sudo -n kubectl"
# would expand as a single bogus command. An array sidesteps IFS entirely.
KUBECTL=()
KUBECTL_DISPLAY=""
detect_kubectl() {
  if kubectl get ns >/dev/null 2>&1; then
    KUBECTL=(kubectl);          KUBECTL_DISPLAY="kubectl"
  elif sudo -n kubectl get ns >/dev/null 2>&1; then
    KUBECTL=(sudo -n kubectl);  KUBECTL_DISPLAY="sudo -n kubectl"
  else
    echo "FATAL: no working kubectl (tried plain and 'sudo -n')." >&2
    exit 1
  fi
}

psql_exec() {
  "${KUBECTL[@]}" -n "$KEYCLOAK_NS" exec -i "$DB_POD" -c postgres -- \
    psql -U postgres -d keycloak -v ON_ERROR_STOP=1 "$@"
}

q() { psql_exec -tAc "$1" | tr -d '[:space:]'; }

echo "════════════════════════════════════════════════════════════"
echo "  03c — master realm passkey-2FA replay  (mode: $MODE)"
echo "════════════════════════════════════════════════════════════"
echo ""

# ─── Pre-flight ───────────────────────────────────────────────────────────
detect_kubectl
echo ">>> [00] kubectl = '$KUBECTL_DISPLAY'; verifying DB pod reachable"
if ! psql_exec -tAc "SELECT 1" >/dev/null 2>&1; then
  echo "FATAL: cannot reach $DB_POD in ns $KEYCLOAK_NS" >&2
  exit 1
fi

echo ">>> [01] Resolve realm_id for '$REALM'"
REALM_ID="$(q "SELECT id FROM realm WHERE name = '$REALM'")"
if [[ -z "$REALM_ID" ]]; then
  echo "FATAL: realm '$REALM' not found" >&2
  exit 1
fi
echo "    realm_id = $REALM_ID"

CONDITIONAL_2FA="browser-webauthn-required Browser - Conditional 2FA"
FORMS="browser-webauthn-required forms"

# ─── Apply (skipped in --check) ───────────────────────────────────────────
if [[ "$MODE" == "apply" ]]; then
  echo ""
  echo "── BEFORE state ──────────────────────────────────────────────"
  psql_exec -c "
    SELECT alias, top_level, built_in FROM authentication_flow
     WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn-required%'
     ORDER BY top_level DESC, alias;
  "

  echo ""
  echo ">>> [02] Apply target posture (single transaction, idempotent)"
  psql_exec <<SQL
BEGIN;

-- ── Flows: create the custom tree if absent (DR / greenfield master) ──

INSERT INTO authentication_flow (id, alias, description, realm_id, provider_id, top_level, built_in)
SELECT gen_random_uuid(), 'browser-webauthn-required',
       'Browser flow: username+password first factor, passkey-preferred 2FA, recovery codes as break-glass',
       '$REALM_ID', 'basic-flow', true, false
 WHERE NOT EXISTS (SELECT 1 FROM authentication_flow
                    WHERE realm_id = '$REALM_ID' AND alias = 'browser-webauthn-required');

INSERT INTO authentication_flow (id, alias, description, realm_id, provider_id, top_level, built_in)
SELECT gen_random_uuid(), '$FORMS',
       'Username+password form then conditional second factor',
       '$REALM_ID', 'basic-flow', false, false
 WHERE NOT EXISTS (SELECT 1 FROM authentication_flow
                    WHERE realm_id = '$REALM_ID' AND alias = '$FORMS');

INSERT INTO authentication_flow (id, alias, description, realm_id, provider_id, top_level, built_in)
SELECT gen_random_uuid(), '$CONDITIONAL_2FA',
       'Passkey-preferred second factor with recovery codes as break-glass',
       '$REALM_ID', 'basic-flow', false, false
 WHERE NOT EXISTS (SELECT 1 FROM authentication_flow
                    WHERE realm_id = '$REALM_ID' AND alias = '$CONDITIONAL_2FA');

-- ── Top-level executions on browser-webauthn-required ──

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-cookie', 2, 10, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-webauthn-required'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'auth-cookie');

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-spnego', 3, 20, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-webauthn-required'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'auth-spnego');

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'identity-provider-redirector', 2, 25, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-webauthn-required'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'identity-provider-redirector');

INSERT INTO authentication_execution (id, realm_id, flow_id, auth_flow_id, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', top.id, forms.id, 2, 30, true
  FROM authentication_flow top, authentication_flow forms
 WHERE top.realm_id   = '$REALM_ID' AND top.alias   = 'browser-webauthn-required'
   AND forms.realm_id = '$REALM_ID' AND forms.alias = '$FORMS'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = top.id AND ae.auth_flow_id = forms.id);

-- ── forms subflow executions ──

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-username-password-form', 0, 10, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = '$FORMS'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'auth-username-password-form');

INSERT INTO authentication_execution (id, realm_id, flow_id, auth_flow_id, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', forms.id, c2fa.id, 1, 20, true
  FROM authentication_flow forms, authentication_flow c2fa
 WHERE forms.realm_id = '$REALM_ID' AND forms.alias = '$FORMS'
   AND c2fa.realm_id  = '$REALM_ID' AND c2fa.alias  = '$CONDITIONAL_2FA'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = forms.id AND ae.auth_flow_id = c2fa.id);

-- ── Conditional 2FA subflow executions ──

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'conditional-user-configured', 0, 10, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = '$CONDITIONAL_2FA'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'conditional-user-configured');

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'webauthn-authenticator', 2, 30, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = '$CONDITIONAL_2FA'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'webauthn-authenticator');

INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-recovery-authn-code-form', 2, 40, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = '$CONDITIONAL_2FA'
   AND NOT EXISTS (SELECT 1 FROM authentication_execution ae
                    WHERE ae.flow_id = f.id AND ae.authenticator = 'auth-recovery-authn-code-form');

-- ── Drift repair: re-assert requirements + the passkey-before-recovery
--    priority invariant even if the rows already existed but drifted. ──

UPDATE authentication_execution ae SET requirement = 2, priority = 30
  FROM authentication_flow af
 WHERE af.id = ae.flow_id AND af.realm_id = '$REALM_ID'
   AND af.alias = '$CONDITIONAL_2FA' AND ae.authenticator = 'webauthn-authenticator';

UPDATE authentication_execution ae SET requirement = 2, priority = 40
  FROM authentication_flow af
 WHERE af.id = ae.flow_id AND af.realm_id = '$REALM_ID'
   AND af.alias = '$CONDITIONAL_2FA' AND ae.authenticator = 'auth-recovery-authn-code-form';

UPDATE authentication_execution ae SET requirement = 0
  FROM authentication_flow af
 WHERE af.id = ae.flow_id AND af.realm_id = '$REALM_ID'
   AND af.alias = '$CONDITIONAL_2FA' AND ae.authenticator = 'conditional-user-configured';

UPDATE authentication_execution ae SET requirement = 0
  FROM authentication_flow af
 WHERE af.id = ae.flow_id AND af.realm_id = '$REALM_ID'
   AND af.alias = '$FORMS' AND ae.authenticator = 'auth-username-password-form';

-- ── Bind the custom flow as the realm browser flow ──

UPDATE realm
   SET browser_flow = (SELECT id FROM authentication_flow
                        WHERE realm_id = '$REALM_ID'
                          AND alias = 'browser-webauthn-required' AND top_level = true)
 WHERE id = '$REALM_ID';

-- ── Required actions ──

UPDATE required_action_provider
   SET enabled = true, default_action = true
 WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register';

INSERT INTO required_action_provider (id, alias, name, realm_id, enabled, default_action, provider_id, priority)
SELECT gen_random_uuid(), 'webauthn-register-passwordless', 'Webauthn Register Passwordless',
       '$REALM_ID', true, false, 'webauthn-register-passwordless', 80
 WHERE NOT EXISTS (SELECT 1 FROM required_action_provider
                    WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register-passwordless');

UPDATE required_action_provider
   SET enabled = true, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register-passwordless';

-- Break-glass: recovery codes stay ENABLED (opt-in). Never disabled here.
UPDATE required_action_provider
   SET enabled = true, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'CONFIGURE_RECOVERY_AUTHN_CODES';

-- Passkey-only 2FA on master: OTP off.
UPDATE required_action_provider
   SET enabled = false, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'CONFIGURE_TOTP';

COMMIT;
SQL

  # WebAuthn policy attributes — upsert one at a time so the script works on
  # a greenfield master where the rows do not exist yet.
  while IFS='|' read -r attr val; do
    psql_exec <<SQL
BEGIN;
INSERT INTO realm_attribute (name, value, realm_id)
SELECT '$attr', '$val', '$REALM_ID'
 WHERE NOT EXISTS (SELECT 1 FROM realm_attribute WHERE realm_id = '$REALM_ID' AND name = '$attr');
UPDATE realm_attribute SET value = '$val' WHERE realm_id = '$REALM_ID' AND name = '$attr';
COMMIT;
SQL
  done <<ATTRS
webAuthnPolicyRpId|$DOMAIN
webAuthnPolicyRpEntityName|$RP_ENTITY_NAME
webAuthnPolicyUserVerificationRequirement|required
webAuthnPolicySignatureAlgorithms|ES256,RS256
webAuthnPolicyCreateTimeout|60
ATTRS

  echo "    committed"

  echo ""
  echo "── AFTER state ───────────────────────────────────────────────"
  psql_exec -c "
    SELECT af.alias AS flow,
           COALESCE(ae.authenticator, '(subflow -> ' || sub.alias || ')') AS step,
           CASE ae.requirement WHEN 0 THEN 'REQUIRED' WHEN 1 THEN 'CONDITIONAL'
                WHEN 2 THEN 'ALTERNATIVE' WHEN 3 THEN 'DISABLED' END AS req,
           ae.priority
      FROM authentication_execution ae
      JOIN authentication_flow af ON af.id = ae.flow_id
      LEFT JOIN authentication_flow sub ON sub.id = ae.auth_flow_id
     WHERE af.realm_id = '$REALM_ID' AND af.alias LIKE 'browser-webauthn-required%'
     ORDER BY af.alias, ae.priority;
  "
fi

# ─── Verification (run in BOTH modes) ─────────────────────────────────────
echo ""
echo ">>> [03] Verify target posture"
FAIL=0
check() { # desc, got, want
  if [[ "$2" != "$3" ]]; then
    echo "  VERIFY FAIL: $1 = '$2' (want '$3')" >&2; FAIL=1
  else
    echo "  ok: $1 = $2"
  fi
}

BOUND="$(q "SELECT alias FROM authentication_flow WHERE id = (SELECT browser_flow FROM realm WHERE id='$REALM_ID')")"
check "realm.browser_flow" "$BOUND" "browser-webauthn-required"

CUSTOM_FLOW="$(q "SELECT count(*) FROM authentication_flow WHERE realm_id='$REALM_ID' AND alias='browser-webauthn-required' AND top_level AND NOT built_in")"
check "custom top-level flow present" "$CUSTOM_FLOW" "1"

UPW_REQ="$(q "SELECT count(*) FROM authentication_execution ae JOIN authentication_flow af ON af.id=ae.flow_id WHERE af.realm_id='$REALM_ID' AND af.alias='$FORMS' AND ae.authenticator='auth-username-password-form' AND ae.requirement=0")"
check "UN/PW form REQUIRED in forms" "$UPW_REQ" "1"

WA_REQ="$(q "SELECT ae.requirement FROM authentication_execution ae JOIN authentication_flow af ON af.id=ae.flow_id WHERE af.realm_id='$REALM_ID' AND af.alias='$CONDITIONAL_2FA' AND ae.authenticator='webauthn-authenticator'")"
check "webauthn-authenticator requirement (2=ALTERNATIVE)" "$WA_REQ" "2"

RC_REQ="$(q "SELECT ae.requirement FROM authentication_execution ae JOIN authentication_flow af ON af.id=ae.flow_id WHERE af.realm_id='$REALM_ID' AND af.alias='$CONDITIONAL_2FA' AND ae.authenticator='auth-recovery-authn-code-form'")"
check "recovery-codes form requirement (2=ALTERNATIVE)" "$RC_REQ" "2"

WA_PRIO="$(q "SELECT ae.priority FROM authentication_execution ae JOIN authentication_flow af ON af.id=ae.flow_id WHERE af.realm_id='$REALM_ID' AND af.alias='$CONDITIONAL_2FA' AND ae.authenticator='webauthn-authenticator'")"
RC_PRIO="$(q "SELECT ae.priority FROM authentication_execution ae JOIN authentication_flow af ON af.id=ae.flow_id WHERE af.realm_id='$REALM_ID' AND af.alias='$CONDITIONAL_2FA' AND ae.authenticator='auth-recovery-authn-code-form'")"
if [[ -n "$WA_PRIO" && -n "$RC_PRIO" && "$WA_PRIO" -lt "$RC_PRIO" ]]; then
  echo "  ok: passkey-before-recovery invariant (webauthn $WA_PRIO < recovery $RC_PRIO)"
else
  echo "  VERIFY FAIL: passkey-before-recovery invariant (webauthn='$WA_PRIO' recovery='$RC_PRIO')" >&2; FAIL=1
fi

RA_WEBAUTHN="$(q "SELECT enabled FROM required_action_provider WHERE realm_id='$REALM_ID' AND alias='webauthn-register'")"
check "webauthn-register enabled" "$RA_WEBAUTHN" "t"

RA_RECOVERY="$(q "SELECT enabled FROM required_action_provider WHERE realm_id='$REALM_ID' AND alias='CONFIGURE_RECOVERY_AUTHN_CODES'")"
check "recovery-codes break-glass enabled" "$RA_RECOVERY" "t"

RA_TOTP="$(q "SELECT enabled FROM required_action_provider WHERE realm_id='$REALM_ID' AND alias='CONFIGURE_TOTP'")"
check "CONFIGURE_TOTP disabled (passkey-only 2FA)" "$RA_TOTP" "f"

RPID="$(q "SELECT value FROM realm_attribute WHERE realm_id='$REALM_ID' AND name='webAuthnPolicyRpId'")"
check "webAuthnPolicyRpId" "$RPID" "$DOMAIN"

UV="$(q "SELECT value FROM realm_attribute WHERE realm_id='$REALM_ID' AND name='webAuthnPolicyUserVerificationRequirement'")"
check "webAuthnPolicyUserVerificationRequirement" "$UV" "required"

if [[ "$FAIL" != "0" ]]; then
  echo ""
  if [[ "$MODE" == "check" ]]; then
    echo "master realm has DRIFTED from the target posture (see above)." >&2
  else
    echo "Post-apply verification FAILED (see above)." >&2
  fi
  exit 2
fi
echo ""
echo ">>> Verification PASSED — master matches the passkey-2FA posture."

# ─── Flush Infinispan flow cache (apply mode only) ────────────────────────
if [[ "$MODE" == "apply" && "$BOUNCE_POD" == "1" ]]; then
  echo ""
  echo ">>> [04] Bouncing $KC_POD to flush Infinispan flow cache"
  "${KUBECTL[@]}" -n "$KEYCLOAK_NS" delete pod "$KC_POD"
  "${KUBECTL[@]}" -n "$KEYCLOAK_NS" wait --for=condition=Ready pod/"$KC_POD" --timeout=180s
  echo "    $KC_POD back online."
elif [[ "$MODE" == "apply" ]]; then
  echo ""
  echo ">>> [04] Skipping pod bounce (--no-bounce). Flush manually:"
  echo "         $KUBECTL_DISPLAY -n $KEYCLOAK_NS delete pod $KC_POD"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  03c complete (mode: $MODE)."
echo "════════════════════════════════════════════════════════════"
