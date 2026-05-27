#!/usr/bin/env bash
# 03b — Keycloak secforge-tenants passkey-required hardening (DB-write replay)
#
# Mirrors the platform realm's `browser-webauthn-required` posture onto the
# `secforge-tenants` realm. Operates via direct Postgres writes against the
# CNPG-managed Keycloak database — per project_keycloak_admin_db_only,
# kcadm and admin-API curl are non-starters on this cluster (jaupole is the
# sole master-realm admin and is WebAuthn-required, so no automated session
# can be established).
#
# Idempotent + safe to re-run. Captures the pre/post state so drift is
# visible at a glance.
#
# WHAT IT CHANGES (in `secforge-tenants` realm only):
#   1. Renames the 5 `browser-webauthn-optional*` authentication_flow rows
#      to `browser-webauthn-required*` (5 flows: top-level + 4 subflows).
#      realm.browser_flow already references the top-level flow by UUID, so
#      this rename re-binds it implicitly with no FK churn.
#   2. Deletes the `auth-otp-form` execution from the Conditional 2FA
#      subflow — TOTP is no longer a 2FA alternative on this realm. The
#      remaining alternatives are webauthn-authenticator + recovery codes.
#   3. Flips `webauthn-register` to default_action=true so new tenants are
#      forced to enroll a passkey at first login (mirrors platform).
#   4. Flips `CONFIGURE_RECOVERY_AUTHN_CODES` to default_action=true so a
#      lost passkey doesn't mean a locked tenant account.
#   5. Bounces keycloak-0 to flush Infinispan cache — direct DB writes
#      don't trigger cache invalidation
#      (project_keycloak_client_secret_rotation_pattern).
#
# WHAT IT DOES NOT TOUCH:
#   - `passwordPolicy` / `webAuthnPolicy*` / brute-force fields — these are
#     declared in secforge-tenants-realm.yaml and survive a realm-import
#     replay. Direct DB drift on these belongs in 03a (currently stale —
#     see header note below).
#   - User credentials. Each existing tenant user keeps whatever they hold
#     today. With this script applied, on next sign-in: a password-only
#     user gets the webauthn-register required action prompt and enrolls a
#     passkey; a passkey-only user (e.g. jaupole@hotmail.com) still needs
#     a password set out-of-band (this flow REQUIRES password before the
#     2FA alternative).
#
# RELATED:
#   - Source of truth for greenfield install:
#     platform/manifests/keycloak/realms/secforge-tenants-realm.yaml
#   - Sibling drift-recovery script (now stale — kcadm no longer works):
#     platform/components/03a-keycloak-realm-hardening.sh
#     Until 03a is refactored to DB writes, it CANNOT run; this script is
#     the only working day-2 replay for the realm-level passkey hardening.
#
# USAGE:
#   ./03b-keycloak-tenants-passkey-required.sh           # apply + bounce
#   ./03b-keycloak-tenants-passkey-required.sh --no-bounce  # apply only
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

BOUNCE_POD=1
if [[ "${1:-}" == "--no-bounce" ]]; then
  BOUNCE_POD=0
fi

psql_exec() {
  kubectl -n "$KEYCLOAK_NS" exec "$DB_POD" -c postgres -- \
    psql -U postgres -d keycloak -v ON_ERROR_STOP=1 "$@"
}

echo "════════════════════════════════════════════════════════════"
echo "  03b — secforge-tenants passkey-required hardening (DB writes)"
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
   WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn%'
   ORDER BY alias;
  SELECT alias, enabled, default_action
    FROM required_action_provider
   WHERE realm_id = '$REALM_ID'
     AND alias IN ('webauthn-register','CONFIGURE_RECOVERY_AUTHN_CODES')
   ORDER BY alias;
  SELECT af.alias AS conditional_2fa_subflow, ae.authenticator
    FROM authentication_execution ae
    JOIN authentication_flow af ON af.id = ae.flow_id
   WHERE af.realm_id = '$REALM_ID'
     AND af.alias LIKE '%Conditional 2FA'
     AND ae.authenticator = 'auth-otp-form';
"

# ─── Apply changes in one transaction ─────────────────────────────────────

echo ""
echo ">>> [02] Apply changes (single transaction)"
psql_exec <<SQL
BEGIN;

-- (1) Rename the five flows. realm.browser_flow points at the top-level
--     flow's UUID so this rename re-binds it implicitly. The order doesn't
--     matter — REPLACE() is per-row.
UPDATE authentication_flow
   SET alias = REPLACE(alias, 'browser-webauthn-optional', 'browser-webauthn-required')
 WHERE realm_id = '$REALM_ID'
   AND alias LIKE 'browser-webauthn-optional%';

-- (2) Drop the OTP Form execution from the Conditional 2FA subflow. After
--     step (1) the subflow alias is 'browser-webauthn-required Browser -
--     Conditional 2FA'; before step (1) it was the -optional variant.
--     The DELETE matches either — safe on partial re-run.
DELETE FROM authentication_execution
 WHERE authenticator = 'auth-otp-form'
   AND flow_id IN (
     SELECT id FROM authentication_flow
      WHERE realm_id = '$REALM_ID'
        AND (alias = 'browser-webauthn-required Browser - Conditional 2FA'
          OR alias = 'browser-webauthn-optional Browser - Conditional 2FA')
   );

-- (3) webauthn-register defaultAction=true
UPDATE required_action_provider
   SET default_action = true,
       enabled = true
 WHERE realm_id = '$REALM_ID'
   AND alias = 'webauthn-register';

-- (4) Recovery codes defaultAction=true
UPDATE required_action_provider
   SET default_action = true,
       enabled = true
 WHERE realm_id = '$REALM_ID'
   AND alias = 'CONFIGURE_RECOVERY_AUTHN_CODES';

COMMIT;
SQL
echo "    committed"

# ─── Post-flight verification ─────────────────────────────────────────────

echo ""
echo "── AFTER state ───────────────────────────────────────────────"
psql_exec -c "
  SELECT alias FROM authentication_flow
   WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn%'
   ORDER BY alias;
  SELECT alias, enabled, default_action
    FROM required_action_provider
   WHERE realm_id = '$REALM_ID'
     AND alias IN ('webauthn-register','CONFIGURE_RECOVERY_AUTHN_CODES')
   ORDER BY alias;
"

# Sanity-check the target state — abort with exit 2 if any field is off.
FAIL=0

# 5 flows, all renamed
WRONG_ALIAS_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_flow
   WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn-optional%'" | tr -d '[:space:]')
if [[ "$WRONG_ALIAS_COUNT" != "0" ]]; then
  echo "VERIFY FAIL: $WRONG_ALIAS_COUNT flow row(s) still named -optional*" >&2
  FAIL=1
fi

RIGHT_ALIAS_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_flow
   WHERE realm_id = '$REALM_ID' AND alias LIKE 'browser-webauthn-required%'" | tr -d '[:space:]')
if [[ "$RIGHT_ALIAS_COUNT" != "5" ]]; then
  echo "VERIFY FAIL: expected 5 -required* flow rows, got $RIGHT_ALIAS_COUNT" >&2
  FAIL=1
fi

# No more OTP form in Conditional 2FA
OTP_COUNT=$(psql_exec -tAc "
  SELECT count(*) FROM authentication_execution ae
    JOIN authentication_flow af ON af.id = ae.flow_id
   WHERE af.realm_id = '$REALM_ID'
     AND af.alias LIKE '%Conditional 2FA'
     AND ae.authenticator = 'auth-otp-form'" | tr -d '[:space:]')
if [[ "$OTP_COUNT" != "0" ]]; then
  echo "VERIFY FAIL: auth-otp-form still present in Conditional 2FA ($OTP_COUNT rows)" >&2
  FAIL=1
fi

# webauthn-register + recovery codes both default_action=true
WR_DEF=$(psql_exec -tAc "
  SELECT default_action FROM required_action_provider
   WHERE realm_id = '$REALM_ID' AND alias = 'webauthn-register'" | tr -d '[:space:]')
if [[ "$WR_DEF" != "t" ]]; then
  echo "VERIFY FAIL: webauthn-register default_action = '$WR_DEF' (expected t)" >&2
  FAIL=1
fi

RC_DEF=$(psql_exec -tAc "
  SELECT default_action FROM required_action_provider
   WHERE realm_id = '$REALM_ID' AND alias = 'CONFIGURE_RECOVERY_AUTHN_CODES'" | tr -d '[:space:]')
if [[ "$RC_DEF" != "t" ]]; then
  echo "VERIFY FAIL: CONFIGURE_RECOVERY_AUTHN_CODES default_action = '$RC_DEF' (expected t)" >&2
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
  echo "    (DB writes don't invalidate Keycloak's in-memory caches —"
  echo "     authentication flow + required-action providers are cached)"
  kubectl -n "$KEYCLOAK_NS" delete pod "$KC_POD"
  echo "    waiting for $KC_POD to become Ready…"
  kubectl -n "$KEYCLOAK_NS" wait --for=condition=Ready pod/"$KC_POD" --timeout=180s
  echo "    $KC_POD back online."
else
  echo ""
  echo ">>> [04] Skipping pod bounce (--no-bounce). Manual step required:"
  echo "         kubectl -n $KEYCLOAK_NS delete pod $KC_POD"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Hardening replay complete."
echo "════════════════════════════════════════════════════════════"
