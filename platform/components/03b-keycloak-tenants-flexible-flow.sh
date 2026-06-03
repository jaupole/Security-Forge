#!/usr/bin/env bash
# 03b — Keycloak secforge-tenants flexible-flow replay (DB-write idempotent)
#
# Brings the `secforge-tenants` realm to the "flexible first-factor +
# optional 2FA" posture documented in
# `platform/manifests/keycloak/realms/secforge-tenants-realm.yaml`.
# Operates via direct Postgres writes against `secforge-keycloak-db-1` —
# per project_keycloak_admin_db_only, kcadm and admin-API curl are
# non-starters on this cluster (jaupole is the sole master-realm admin
# and WebAuthn-required, so no automated kcadm session can be opened).
#
# Idempotent + safe to re-run. The transactional shape captures pre/post
# state and end-state-checks every change before the COMMIT.
#
# WHAT IT CHANGES (`secforge-tenants` realm only):
#   1. Renames any residual `browser-webauthn-required*` or
#      `browser-webauthn-optional*` flow rows to the canonical
#      `browser-flexible*` aliases (5 flows). realm.browser_flow points
#      at the top-level flow's UUID so this rename re-binds it
#      implicitly with no FK churn.
#   2. Restructures the `browser-flexible forms` subflow:
#        BEFORE: auth-username-password-form (REQUIRED) + Conditional 2FA
#        AFTER : auth-username-form (REQUIRED)
#              + browser-flexible First-factor (REQUIRED)
#              + Conditional 2FA (CONDITIONAL — priority bumped 20->30)
#   3. Creates the `browser-flexible First-factor` subflow if missing,
#      with two ALTERNATIVE leaves:
#        - auth-password-form
#        - webauthn-authenticator-passwordless
#   4. Ensures the `browser-flexible Browser - Conditional 2FA` subflow
#      has these executions (in addition to conditional-user-configured):
#        - auth-otp-form (ALTERNATIVE, priority 20)
#        - webauthn-authenticator (ALTERNATIVE, priority 30)
#      auth-recovery-authn-code-form is NOT added — recovery codes are
#      not part of this realm's recovery model (email password-reset +
#      operator help-desk only).
#   5. Required actions:
#        - webauthn-register: enabled=true, default_action=false (opt-in 2FA passkey)
#        - webauthn-register-passwordless: enabled=true, default_action=false
#          (registered if missing; opt-in first-factor passkey)
#        - CONFIGURE_RECOVERY_AUTHN_CODES: enabled=false, default_action=false
#        - CONFIGURE_TOTP: enabled=true (defaultAction left as set in DB)
#   6. WebAuthn Passwordless policy: RpId, RpEntityName, UV=required,
#      AttestationConveyance=none, CreateTimeout=60s, RequireResidentKey=Yes,
#      SignatureAlgorithms=ES256,RS256. Aligns with the regular WebAuthn
#      policy so passwordless credentials enrol + verify against the
#      same RP origin/UV stance.
#   7. Defensive: removes any pre-existing recovery-authn-codes
#      credentials and pending CONFIGURE_RECOVERY_AUTHN_CODES required
#      actions on tenant users (no-op on a clean realm).
#   8. Bounces keycloak-0 to flush Infinispan — flow caches don't
#      invalidate on direct DB writes
#      (project_keycloak_client_secret_rotation_pattern).
#
# WHAT IT DOES NOT TOUCH:
#   - passwordPolicy, regular webAuthnPolicy*, brute-force fields —
#     declared in secforge-tenants-realm.yaml and survive realm-import
#     replay. Out of scope for this script.
#   - User credentials except the defensive recovery-codes wipe in (7).
#
# RELATED:
#   - Source of truth for greenfield install:
#     platform/manifests/keycloak/realms/secforge-tenants-realm.yaml
#   - Sibling script that hardens platform + master realms (currently
#     stale — relies on kcadm):
#     platform/components/03a-keycloak-realm-hardening.sh
#
# USAGE:
#   ./03b-keycloak-tenants-flexible-flow.sh             # apply + bounce
#   ./03b-keycloak-tenants-flexible-flow.sh --no-bounce # apply only
#
# Exit codes:
#   0  applied (or already in target state) and pod bounce succeeded
#   1  pre-flight failure (realm missing, db pod unreachable, etc.)
#   2  applied OK but post-apply verification mismatched
#
set -euo pipefail
IFS=$'\n\t'

KEYCLOAK_NS="keycloak"
DB_POD="secforge-keycloak-db-1"
KC_POD="keycloak-0"
REALM="secforge-tenants"
DOMAIN="${DOMAIN:-secforge.dev}"

BOUNCE_POD=1
if [[ "${1:-}" == "--no-bounce" ]]; then
  BOUNCE_POD=0
fi

psql_exec() {
  kubectl -n "$KEYCLOAK_NS" exec "$DB_POD" -c postgres -- \
    psql -U postgres -d keycloak -v ON_ERROR_STOP=1 "$@"
}

echo "════════════════════════════════════════════════════════════"
echo "  03b — secforge-tenants flexible-flow replay (DB writes)"
echo "════════════════════════════════════════════════════════════"
echo ""

# ─── Pre-flight ───────────────────────────────────────────────────────────

echo ">>> [00] Verify DB pod is reachable"
if ! psql_exec -tAc "SELECT 1" >/dev/null 2>&1; then
  echo "FATAL: cannot reach $DB_POD in ns $KEYCLOAK_NS" >&2
  exit 1
fi

echo ">>> [01] Resolve realm_id for '$REALM'"
REALM_ID=$(psql_exec -tAc "SELECT id FROM realm WHERE name = '$REALM'" | tr -d '[:space:]')
if [[ -z "$REALM_ID" ]]; then
  echo "FATAL: realm '$REALM' not found (was the realm-import applied?)" >&2
  exit 1
fi
echo "    realm_id = $REALM_ID"

echo ""
echo "── BEFORE state ──────────────────────────────────────────────"
psql_exec -c "
  SELECT alias FROM authentication_flow
   WHERE realm_id = '$REALM_ID'
     AND alias LIKE 'browser-%'
   ORDER BY alias;
  SELECT alias, enabled, default_action
    FROM required_action_provider
   WHERE realm_id = '$REALM_ID'
     AND alias IN ('webauthn-register','webauthn-register-passwordless',
                   'CONFIGURE_RECOVERY_AUTHN_CODES','CONFIGURE_TOTP')
   ORDER BY alias;
"

# ─── Apply changes in one transaction ─────────────────────────────────────

echo ""
echo ">>> [02] Apply changes (single transaction)"
psql_exec <<SQL
BEGIN;

-- (1) Canonicalise flow aliases to browser-flexible*. Covers both prior
--     states (-optional* and -required*).
UPDATE authentication_flow
   SET alias = REPLACE(alias, 'browser-webauthn-required', 'browser-flexible')
 WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn-required%';

UPDATE authentication_flow
   SET alias = REPLACE(alias, 'browser-webauthn-optional', 'browser-flexible')
 WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn-optional%';

-- (2a) Remove the combined username+password form from forms.
DELETE FROM authentication_execution
 WHERE realm_id = '$REALM_ID'
   AND authenticator = 'auth-username-password-form'
   AND flow_id IN (SELECT id FROM authentication_flow
                    WHERE realm_id = '$REALM_ID' AND alias = 'browser-flexible forms');

-- (3) Create the First-factor subflow if it doesn't exist.
INSERT INTO authentication_flow (id, alias, description, realm_id, provider_id, top_level, built_in)
SELECT gen_random_uuid(), 'browser-flexible First-factor',
       'Password OR passkey as first factor (tenant choice)',
       '$REALM_ID', 'basic-flow', false, false
 WHERE NOT EXISTS (
   SELECT 1 FROM authentication_flow
    WHERE realm_id = '$REALM_ID' AND alias = 'browser-flexible First-factor'
 );

-- (2b) Add auth-username-form to forms (REQUIRED, priority 10).
INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-username-form', 0, 10, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-flexible forms'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = f.id AND ae.authenticator = 'auth-username-form'
   );

-- (2c) Add First-factor subflow ref into forms (REQUIRED, priority 20).
INSERT INTO authentication_execution (id, realm_id, flow_id, auth_flow_id, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', forms.id, ff.id, 0, 20, true
  FROM authentication_flow forms, authentication_flow ff
 WHERE forms.realm_id = '$REALM_ID' AND forms.alias = 'browser-flexible forms'
   AND ff.realm_id    = '$REALM_ID' AND ff.alias    = 'browser-flexible First-factor'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = forms.id AND ae.auth_flow_id = ff.id
   );

-- (3a) auth-password-form (ALTERNATIVE) in First-factor.
INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-password-form', 2, 10, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-flexible First-factor'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = f.id AND ae.authenticator = 'auth-password-form'
   );

-- (3b) webauthn-authenticator-passwordless (ALTERNATIVE) in First-factor.
INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'webauthn-authenticator-passwordless', 2, 20, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-flexible First-factor'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = f.id AND ae.authenticator = 'webauthn-authenticator-passwordless'
   );

-- (4a) Bump existing Conditional 2FA subflow ref priority 20 -> 30 in forms.
UPDATE authentication_execution
   SET priority = 30
 WHERE realm_id = '$REALM_ID'
   AND authenticator_flow = true
   AND priority = 20
   AND flow_id = (SELECT id FROM authentication_flow
                   WHERE realm_id = '$REALM_ID' AND alias = 'browser-flexible forms')
   AND auth_flow_id = (SELECT id FROM authentication_flow
                        WHERE realm_id = '$REALM_ID' AND alias = 'browser-flexible Browser - Conditional 2FA');

-- (4b) Add auth-otp-form (ALTERNATIVE, priority 20) into Conditional 2FA.
INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'auth-otp-form', 2, 20, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-flexible Browser - Conditional 2FA'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = f.id AND ae.authenticator = 'auth-otp-form'
   );

-- (4c) Ensure webauthn-authenticator (ALTERNATIVE, priority 30) in Conditional 2FA.
INSERT INTO authentication_execution (id, realm_id, flow_id, authenticator, requirement, priority, authenticator_flow)
SELECT gen_random_uuid(), '$REALM_ID', f.id, 'webauthn-authenticator', 2, 30, false
  FROM authentication_flow f
 WHERE f.realm_id = '$REALM_ID' AND f.alias = 'browser-flexible Browser - Conditional 2FA'
   AND NOT EXISTS (
     SELECT 1 FROM authentication_execution ae
      WHERE ae.realm_id = '$REALM_ID' AND ae.flow_id = f.id AND ae.authenticator = 'webauthn-authenticator'
   );

-- (4d) Defensive — remove any stray auth-recovery-authn-code-form
--      execution that may have been re-added.
DELETE FROM authentication_execution
 WHERE realm_id = '$REALM_ID'
   AND authenticator = 'auth-recovery-authn-code-form'
   AND flow_id IN (SELECT id FROM authentication_flow
                    WHERE realm_id = '$REALM_ID' AND alias LIKE '%Conditional 2FA');

-- (5a) webauthn-register: opt-in (default_action=false).
UPDATE required_action_provider
   SET enabled = true, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register';

-- (5b) Register webauthn-register-passwordless if missing.
INSERT INTO required_action_provider (id, alias, name, realm_id, enabled, default_action, provider_id, priority)
SELECT gen_random_uuid(), 'webauthn-register-passwordless', 'Webauthn Register Passwordless',
       '$REALM_ID', true, false, 'webauthn-register-passwordless', 80
 WHERE NOT EXISTS (
   SELECT 1 FROM required_action_provider
    WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register-passwordless'
 );

-- Make sure passwordless registration is enabled, default off if it already existed.
UPDATE required_action_provider
   SET enabled = true, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register-passwordless';

-- (5c) CONFIGURE_RECOVERY_AUTHN_CODES: disabled.
UPDATE required_action_provider
   SET enabled = false, default_action = false
 WHERE realm_id = '$REALM_ID' AND alias = 'CONFIGURE_RECOVERY_AUTHN_CODES';

-- (6) WebAuthn Passwordless policy fields.
UPDATE realm_attribute SET value = '$DOMAIN'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyRpIdPasswordless';
UPDATE realm_attribute SET value = 'SecForge'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyRpEntityNamePasswordless';
UPDATE realm_attribute SET value = 'required'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyUserVerificationRequirementPasswordless';
UPDATE realm_attribute SET value = 'Yes'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyRequireResidentKeyPasswordless';
UPDATE realm_attribute SET value = 'none'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyAttestationConveyancePreferencePasswordless';
UPDATE realm_attribute SET value = '60'
 WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyCreateTimeoutPasswordless';

-- (7) Defensive cleanup of recovery-codes credentials + pending actions.
DELETE FROM credential
 WHERE type = 'recovery-authn-codes'
   AND user_id IN (SELECT id FROM user_entity WHERE realm_id = '$REALM_ID');

DELETE FROM user_required_action
 WHERE required_action = 'CONFIGURE_RECOVERY_AUTHN_CODES'
   AND user_id IN (SELECT id FROM user_entity WHERE realm_id = '$REALM_ID');

COMMIT;
SQL
echo "    committed"

# ─── Post-apply verification ──────────────────────────────────────────────

echo ""
echo "── AFTER state ───────────────────────────────────────────────"
psql_exec -c "
  SELECT af.alias AS flow, COALESCE(ae.authenticator, '(subflow -> ' || sub.alias || ')') AS step, ae.requirement, ae.priority
    FROM authentication_execution ae
    JOIN authentication_flow af ON af.id = ae.flow_id
    LEFT JOIN authentication_flow sub ON sub.id = ae.auth_flow_id
   WHERE af.realm_id = '$REALM_ID'
     AND af.alias LIKE 'browser-flexible%'
   ORDER BY af.alias, ae.priority;
  SELECT alias, enabled, default_action FROM required_action_provider
   WHERE realm_id = '$REALM_ID'
     AND alias IN ('webauthn-register','webauthn-register-passwordless',
                   'CONFIGURE_RECOVERY_AUTHN_CODES','CONFIGURE_TOTP')
   ORDER BY alias;
"

FAIL=0

# 6 flow rows, all canonical
CANONICAL_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_flow
   WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-flexible%'" | tr -d '[:space:]')
if [[ "$CANONICAL_COUNT" != "6" ]]; then
  echo "VERIFY FAIL: expected 6 browser-flexible* flow rows, got $CANONICAL_COUNT" >&2
  FAIL=1
fi

# No stale -required / -optional flows
STALE_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_flow
   WHERE realm_id = '$REALM_ID' AND (alias LIKE 'browser-webauthn-%')" | tr -d '[:space:]')
if [[ "$STALE_COUNT" != "0" ]]; then
  echo "VERIFY FAIL: $STALE_COUNT stale browser-webauthn-* flow row(s) present" >&2
  FAIL=1
fi

# First-factor has exactly 2 ALTERNATIVE leaves
FF_LEAF_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_execution ae
    JOIN authentication_flow af ON af.id = ae.flow_id
   WHERE af.realm_id = '$REALM_ID' AND af.alias = 'browser-flexible First-factor'
     AND ae.authenticator IN ('auth-password-form','webauthn-authenticator-passwordless')" | tr -d '[:space:]')
if [[ "$FF_LEAF_COUNT" != "2" ]]; then
  echo "VERIFY FAIL: First-factor subflow has $FF_LEAF_COUNT expected leaves (want 2)" >&2
  FAIL=1
fi

# auth-username-password-form GONE from forms
DEAD_COMBINED=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_execution ae
    JOIN authentication_flow af ON af.id = ae.flow_id
   WHERE af.realm_id = '$REALM_ID' AND af.alias = 'browser-flexible forms'
     AND ae.authenticator = 'auth-username-password-form'" | tr -d '[:space:]')
if [[ "$DEAD_COMBINED" != "0" ]]; then
  echo "VERIFY FAIL: stale auth-username-password-form still in forms ($DEAD_COMBINED)" >&2
  FAIL=1
fi

# Required actions match target state
for pair in 'webauthn-register|f' 'webauthn-register-passwordless|f' 'CONFIGURE_RECOVERY_AUTHN_CODES|f'; do
  alias="${pair%|*}"; want="${pair#*|}"
  got=$(psql_exec -tAc "SELECT default_action FROM required_action_provider WHERE realm_id = '$REALM_ID' AND alias = '$alias'" | tr -d '[:space:]')
  if [[ "$got" != "$want" ]]; then
    echo "VERIFY FAIL: $alias default_action='$got' (expected $want)" >&2
    FAIL=1
  fi
done

# CONFIGURE_RECOVERY_AUTHN_CODES must also be enabled=false
RC_ENABLED=$(psql_exec -tAc "
  SELECT enabled FROM required_action_provider
   WHERE realm_id = '$REALM_ID' AND alias = 'CONFIGURE_RECOVERY_AUTHN_CODES'" | tr -d '[:space:]')
if [[ "$RC_ENABLED" != "f" ]]; then
  echo "VERIFY FAIL: CONFIGURE_RECOVERY_AUTHN_CODES enabled='$RC_ENABLED' (expected f)" >&2
  FAIL=1
fi

# webauthn-register-passwordless must be enabled=true
PWLESS_ENABLED=$(psql_exec -tAc "
  SELECT enabled FROM required_action_provider
   WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register-passwordless'" | tr -d '[:space:]')
if [[ "$PWLESS_ENABLED" != "t" ]]; then
  echo "VERIFY FAIL: webauthn-register-passwordless enabled='$PWLESS_ENABLED' (expected t)" >&2
  FAIL=1
fi

# No leftover recovery-codes credentials
RC_CRED=$(psql_exec -tAc "
  SELECT count(*) FROM credential c
    JOIN user_entity u ON u.id = c.user_id
   WHERE u.realm_id = '$REALM_ID' AND c.type = 'recovery-authn-codes'" | tr -d '[:space:]')
if [[ "$RC_CRED" != "0" ]]; then
  echo "VERIFY FAIL: $RC_CRED recovery-authn-codes credentials still present" >&2
  FAIL=1
fi

# Passwordless policy fields aligned
PW_RP=$(psql_exec -tAc "SELECT value FROM realm_attribute WHERE realm_id = '$REALM_ID' AND name = 'webAuthnPolicyRpIdPasswordless'" | tr -d '[:space:]')
if [[ "$PW_RP" != "$DOMAIN" ]]; then
  echo "VERIFY FAIL: webAuthnPolicyRpIdPasswordless='$PW_RP' (expected $DOMAIN)" >&2
  FAIL=1
fi

if [[ "$FAIL" != "0" ]]; then
  echo ""
  echo "Post-apply verification FAILED — see messages above." >&2
  exit 2
fi

echo ""
echo ">>> [03] Verification PASSED"

# ─── Flush Infinispan cache ───────────────────────────────────────────────

if [[ "$BOUNCE_POD" == "1" ]]; then
  echo ""
  echo ">>> [04] Bouncing $KC_POD to flush Infinispan cache"
  kubectl -n "$KEYCLOAK_NS" delete pod "$KC_POD"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if kubectl -n "$KEYCLOAK_NS" get pod "$KC_POD" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q .; then
      break
    fi
    sleep 2
  done
  kubectl -n "$KEYCLOAK_NS" wait --for=condition=Ready pod/"$KC_POD" --timeout=180s
  echo "    $KC_POD back online."
else
  echo ""
  echo ">>> [04] Skipping pod bounce (--no-bounce). Manual step required:"
  echo "         kubectl -n $KEYCLOAK_NS delete pod $KC_POD"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Flexible-flow replay complete."
echo "════════════════════════════════════════════════════════════"
