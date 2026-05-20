#!/usr/bin/env bash
# 03a — Keycloak `platform` realm hardening replay (DR-safe + idempotent)
#
# Depends on: 03-keycloak.sh (Keycloak Operator + Keycloak CR + initial
# KeycloakRealmImport CR creating the `platform` realm with the baseline
# config from `keycloak-platform-realm` Secret).
#
# Why this exists: KeycloakRealmImport is one-shot — the operator imports
# the realm at first reconcile and then ignores subsequent CR updates. The
# hardening flips performed during the 2026-05-14 sprint were applied LIVE
# via kcadm and were NOT reflected back into the import Secret. Without
# this script, a DR rebuild would come up with the pre-hardening config:
#
#   - browserFlow:   `browser` (TOTP-permitting) instead of `browser-webauthn-required`
#   - failureFactor: 5 / 900s wait / 60s increment  (way too lenient)
#   - passwordPolicy: length(12), no HIBP, no notEmail
#   - webAuthnPolicy: defaults, no RpId, preferred user verification
#   - requiredActions: CONFIGURE_TOTP=defaultAction, webauthn-register=not-default
#
# This script applies all the hardening idempotently. Safe to re-run; each
# stage checks current state before mutating.
#
# AUTH PREREQUISITE: kcadm credentials must already be cached in the
# keycloak-0 pod's ~/.keycloak/kcadm.config. Run:
#
#   kubectl -n keycloak exec -it keycloak-0 -- /opt/keycloak/bin/kcadm.sh \
#     config credentials \
#     --server https://keycloak-service.keycloak.svc.cluster.local:8443 \
#     --realm master --user <real-admin>
#
# (See docs/03-runbooks/keycloak-realm-hardening-replay.md if it exists.)
#
# NOT covered (still requires manual prep on a fresh DR cluster):
#   - HIBP blacklist file `Pwdb_top-100000.txt` must exist at
#     /opt/keycloak/data/password-blacklists/ inside the pod BEFORE the
#     passwordPolicy is set (or password evaluation will throw). On a
#     fresh cluster, copy it in via:
#       kubectl -n keycloak cp Pwdb_top-100000.txt \
#         keycloak-0:/opt/keycloak/data/password-blacklists/

set -euo pipefail
IFS=$'\n\t'

REALM="platform"
KEYCLOAK_POD="keycloak-0"
KEYCLOAK_NS="keycloak"

kc() {
  kubectl -n "$KEYCLOAK_NS" exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh "$@"
}

echo ">>> [00] Verify kcadm cache is populated"
if ! kc get serverinfo --fields systemInfo >/dev/null 2>&1; then
  echo "FATAL: kcadm not authenticated. See AUTH PREREQUISITE in script header." >&2
  exit 1
fi

echo ">>> [01] Verify HIBP blacklist file is present (fatal — invariant of the image)"
if ! kubectl -n "$KEYCLOAK_NS" exec "$KEYCLOAK_POD" -- \
     test -f /opt/keycloak/data/password-blacklists/Pwdb_top-100000.txt; then
  echo "FATAL: Pwdb_top-100000.txt missing from /opt/keycloak/data/password-blacklists/" >&2
  echo "       This file should be baked into the SecForge custom Keycloak image" >&2
  echo "       at ghcr.io/secforge/keycloak — its absence means the running pod is" >&2
  echo "       on the stock upstream image (or a different overlay)." >&2
  echo "       Check 'kubectl -n keycloak get pod keycloak-0 -o jsonpath={.spec.containers[*].image}'" >&2
  echo "       and the Keycloak CR spec.image. Build pipeline:" >&2
  echo "         .github/workflows/keycloak-image-build.yml" >&2
  echo "       Image source: platform/manifests/keycloak/image/Dockerfile" >&2
  exit 1
fi

echo ">>> [02] Realm-level hardening fields (incl. session lifetimes)"
# Session lifetimes: regular 15min idle / 8h absolute; remember-me
# capped to 8h idle / 24h absolute (2026-05-19 — production session
# hygiene, was 30d / 7d idle). KeycloakRealmImport is one-shot so the
# import Secret's values do not propagate to a running realm; this
# stage is the authoritative replay.
kc update "realms/$REALM" \
  -s 'passwordPolicy="length(14) and digits(1) and lowerCase(1) and upperCase(1) and specialChars(1) and notUsername(undefined) and notEmail(undefined) and passwordHistory(5) and forceExpiredPasswordChange(365) and passwordBlacklist(Pwdb_top-100000.txt)"' \
  -s 'failureFactor=10' \
  -s 'maxFailureWaitSeconds=3600' \
  -s 'waitIncrementSeconds=120' \
  -s 'bruteForceProtected=true' \
  -s 'sslRequired="external"' \
  -s 'registrationAllowed=false' \
  -s 'ssoSessionIdleTimeout=900' \
  -s 'ssoSessionMaxLifespan=28800' \
  -s 'ssoSessionIdleTimeoutRememberMe=28800' \
  -s 'ssoSessionMaxLifespanRememberMe=86400'

echo ">>> [03] WebAuthn policy (RpId, RpEntityName, required user verification)"
kc update "realms/$REALM" \
  -s 'webAuthnPolicyRpId="secforge.dev"' \
  -s 'webAuthnPolicyRpEntityName="SecForge Platform"' \
  -s 'webAuthnPolicyUserVerificationRequirement="required"' \
  -s 'webAuthnPolicyAttestationConveyancePreference="none"' \
  -s 'webAuthnPolicyCreateTimeout=60' \
  -s 'webAuthnPolicySignatureAlgorithms=["ES256","RS256"]'

echo ">>> [04] Custom browser-webauthn-required flow (copy of browser, OTP→WebAuthn)"
FLOW_ALIAS="browser-webauthn-required"
if kc get authentication/flows -r "$REALM" | jq -e --arg a "$FLOW_ALIAS" '.[] | select(.alias==$a)' >/dev/null; then
  echo "    flow $FLOW_ALIAS already exists — skipping copy"
else
  echo "    copying built-in 'browser' flow → $FLOW_ALIAS"
  kc create "authentication/flows/browser/copy" -r "$REALM" -s "newName=$FLOW_ALIAS"

  echo "    locating OTP Form execution in the new flow"
  OTP_EXEC_ID=$(kc get "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM" \
    | jq -r '.[] | select(.providerId=="auth-otp-form") | .id // empty')
  if [[ -n "$OTP_EXEC_ID" ]]; then
    echo "    removing OTP Form execution ($OTP_EXEC_ID)"
    kc delete "authentication/executions/$OTP_EXEC_ID" -r "$REALM"
  fi

  echo "    locating Conditional-2FA subflow alias for execution insertion"
  COND_2FA_ALIAS=$(kc get "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM" \
    | jq -r '.[] | select(.displayName | test("Conditional 2FA"; "i")) | .displayName // empty' | head -1)
  if [[ -z "$COND_2FA_ALIAS" ]]; then
    echo "FATAL: could not locate Conditional 2FA subflow inside $FLOW_ALIAS" >&2; exit 2
  fi

  echo "    adding WebAuthn Authenticator under '$COND_2FA_ALIAS'"
  kc create "authentication/flows/$COND_2FA_ALIAS/executions/execution" -r "$REALM" \
    -s 'provider="webauthn-authenticator"'

  echo "    adding Recovery Authentication Code Form fallback"
  kc create "authentication/flows/$COND_2FA_ALIAS/executions/execution" -r "$REALM" \
    -s 'provider="auth-recovery-authn-code-form"'

  echo "    marking both as ALTERNATIVE"
  for prov in webauthn-authenticator auth-recovery-authn-code-form; do
    EID=$(kc get "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM" \
      | jq -r --arg p "$prov" '.[] | select(.providerId==$p) | .id // empty')
    [[ -n "$EID" ]] && kc update "authentication/executions/$EID" -r "$REALM" \
      -s 'requirement="ALTERNATIVE"'
  done
fi

echo ">>> [05] Bind realm browserFlow to $FLOW_ALIAS"
CURRENT_FLOW=$(kc get "realms/$REALM" | jq -r .browserFlow)
if [[ "$CURRENT_FLOW" != "$FLOW_ALIAS" ]]; then
  kc update "realms/$REALM" -s "browserFlow=\"$FLOW_ALIAS\""
  echo "    bound (was: $CURRENT_FLOW)"
else
  echo "    already bound — skipping"
fi

echo ">>> [06] Required actions: enable webauthn-register as defaultAction"
WA_STATE=$(kc get "authentication/required-actions/webauthn-register" -r "$REALM" \
  | jq -r '{enabled, defaultAction} | tostring')
if [[ "$WA_STATE" != '{"enabled":true,"defaultAction":true}' ]]; then
  kc update "authentication/required-actions/webauthn-register" -r "$REALM" \
    -s 'enabled=true' -s 'defaultAction=true' -s 'priority=70'
  echo "    enabled (was: $WA_STATE)"
else
  echo "    already enabled+default — skipping"
fi

echo ">>> [07] Required actions: disable CONFIGURE_TOTP defaultAction"
if kc get "authentication/required-actions/CONFIGURE_TOTP" -r "$REALM" 2>/dev/null \
     | jq -e '.defaultAction == true' >/dev/null; then
  kc update "authentication/required-actions/CONFIGURE_TOTP" -r "$REALM" \
    -s 'defaultAction=false'
  echo "    cleared defaultAction (kept enabled so existing TOTP users still resolve)"
else
  echo "    CONFIGURE_TOTP not defaultAction — skipping"
fi

echo ">>> [08] Required actions: ensure CONFIGURE_RECOVERY_AUTHN_CODES enabled+default"
RC_STATE=$(kc get "authentication/required-actions/CONFIGURE_RECOVERY_AUTHN_CODES" -r "$REALM" \
  | jq -r '{enabled, defaultAction} | tostring')
if [[ "$RC_STATE" != '{"enabled":true,"defaultAction":true}' ]]; then
  kc update "authentication/required-actions/CONFIGURE_RECOVERY_AUTHN_CODES" -r "$REALM" \
    -s 'enabled=true' -s 'defaultAction=true'
  echo "    enabled (was: $RC_STATE)"
else
  echo "    already enabled+default — skipping"
fi

echo ""
echo "=== Hardening replay complete. Verifying final state ==="
kc get "realms/$REALM" | jq '{
  browserFlow,
  passwordPolicy,
  webAuthnPolicyRpId,
  webAuthnPolicyUserVerificationRequirement,
  failureFactor,
  maxFailureWaitSeconds,
  waitIncrementSeconds,
  bruteForceProtected,
  registrationAllowed,
  ssoSessionIdleTimeout,
  ssoSessionMaxLifespan,
  ssoSessionIdleTimeoutRememberMe,
  ssoSessionMaxLifespanRememberMe
}'
echo ""
echo "=== Default required actions ==="
kc get "authentication/required-actions" -r "$REALM" \
  | jq '[.[] | select(.defaultAction == true) | .alias]'
