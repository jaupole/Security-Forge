#!/usr/bin/env bash
# 03a — Keycloak realm hardening replay (multi-realm, DR-safe + idempotent)
#
# ─── Status as of 2026-05-23 (Shape B realm split) ───────────────────────
#
# Hardens BOTH `platform` AND `secforge-tenants` realms. Per-realm
# differences are captured in the two `harden_realm` calls at the
# bottom of this file:
#
#                                    platform              secforge-tenants
#   browserFlow alias                browser-webauthn-     browser-webauthn-
#                                    required              optional
#   OTP Form in flow                 removed (passkey-     kept (TOTP is an
#                                    only 2FA)             alternative)
#   webauthn-register defaultAction  true (forced)         false (opt-in)
#   recovery-codes defaultAction     true (forced)         false (opt-in)
#   session idle / max               900 / 28800           1800 / 43200
#                                    (15 min / 8 h)        (30 min / 12 h)
#   WebAuthn RpEntityName            SecForge Platform     SecForge
#
# Stages [02], [03], [06], [07], [08] are also declared in the realm-
# import YAMLs at platform/manifests/keycloak/realms/{platform,
# secforge-tenants}-realm.yaml — that is the source of truth for
# greenfield install. THIS SCRIPT remains the source of truth for
# day-2 drift recovery — both must stay aligned; if you change one,
# change the other.
#
# Stages [04]+[05] (custom authentication flow with WebAuthn +
# recovery-code subflow) ARE declared in both realm-import YAMLs.
# This script still applies them as a safety net in case realm-import
# flow-handling drifts on a future Keycloak version, and as the
# day-2 drift recovery path.
#
# WHEN TO RUN THIS SCRIPT:
#   - On a greenfield install AFTER realm-import has completed, as a
#     safety net for stages 04+05 (realm-import's flow-import handling
#     is version-sensitive; the explicit kcadm copy+modify here is the
#     reliable path).
#   - On any day-2 cluster where drift is suspected (someone weakened
#     a setting via the admin UI).
#   - NOT on every install — most fields are now declarative.
#
# USAGE:
#   ./03a-keycloak-realm-hardening.sh                  # harden all realms
#   ./03a-keycloak-realm-hardening.sh platform         # platform only
#   ./03a-keycloak-realm-hardening.sh secforge-tenants # tenants only
#
# Depends on: 03-keycloak.sh (Keycloak Operator + Keycloak CR + initial
# KeycloakRealmImport CRs for both realms with the baseline config from
# the corresponding `keycloak-*-realm` Secrets).
#
# Realms that do not exist yet are skipped with a warning (so this can
# run safely during a phased rollout of the Shape B realm split).
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
#     /opt/keycloak/data/password-blacklists/ inside the pod BEFORE
#     either realm's passwordPolicy is set. The custom SecForge
#     Keycloak image bakes this in; stages [01] verifies its presence.

set -euo pipefail
IFS=$'\n\t'

KEYCLOAK_POD="keycloak-0"
KEYCLOAK_NS="keycloak"

# Password policy is identical across realms — both apply the same
# baseline. Defined once here, referenced inside harden_realm.
#
# NIST SP 800-63B / CLAUDE.md rule 3: length + breach-check ONLY.
# Character-class composition (digits/upper/lower/special), forced
# rotation (forceExpiredPasswordChange) and history(5) were REMOVED
# 2026-06-02 — the project hard-NOs forbid them and the evidence base
# (NIST 800-63B, OWASP) shows they weaken security (predictable
# patterns, reuse). Do not re-add without a written CLAUDE.md exception.
PASSWORD_POLICY='length(14) and notUsername(undefined) and notEmail(undefined) and passwordBlacklist(Pwdb_top-100000.txt)'

# Remember-me lifetimes are identical across realms (8 h idle / 24 h
# absolute — production session hygiene per 2026-05-19 hardening).
REMEMBER_ME_IDLE=28800
REMEMBER_ME_MAX=86400

kc() {
  kubectl -n "$KEYCLOAK_NS" exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh "$@"
}

# ─── Per-realm hardening function ─────────────────────────────────────────
#
# Args (positional):
#   $1 realm                       Realm name (platform / secforge-tenants)
#   $2 flow_alias                  Custom browser flow alias to copy+modify
#   $3 rp_entity_name              WebAuthn RpEntityName (displayed at login)
#   $4 idle_timeout                ssoSessionIdleTimeout (seconds)
#   $5 max_lifespan                ssoSessionMaxLifespan (seconds)
#   $6 remove_otp_from_flow        "true"  → drop OTP Form from custom flow
#                                  "false" → keep OTP Form (tenants TOTP path)
#   $7 webauthn_register_default   "true"  → defaultAction=true (forced)
#                                  "false" → enabled but opt-in
#   $8 recovery_codes_default      "true"  → defaultAction=true (forced)
#                                  "false" → enabled but opt-in
harden_realm() {
  local realm="$1"
  local flow_alias="$2"
  local rp_entity_name="$3"
  local idle_timeout="$4"
  local max_lifespan="$5"
  local remove_otp_from_flow="$6"
  local webauthn_register_default="$7"
  local recovery_codes_default="$8"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Hardening realm: $realm"
  echo "════════════════════════════════════════════════════════════"

  if ! kc get "realms/$realm" >/dev/null 2>&1; then
    echo "WARNING: realm '$realm' does not exist yet — skipping." >&2
    echo "         (Run 03-keycloak.sh first to import the realm.)" >&2
    return 0
  fi

  echo ">>> [02:$realm] Realm-level hardening fields (incl. session lifetimes)"
  kc update "realms/$realm" \
    -s "passwordPolicy=\"$PASSWORD_POLICY\"" \
    -s 'failureFactor=10' \
    -s 'maxFailureWaitSeconds=3600' \
    -s 'waitIncrementSeconds=120' \
    -s 'bruteForceProtected=true' \
    -s 'sslRequired="external"' \
    -s 'registrationAllowed=false' \
    -s "ssoSessionIdleTimeout=$idle_timeout" \
    -s "ssoSessionMaxLifespan=$max_lifespan" \
    -s "ssoSessionIdleTimeoutRememberMe=$REMEMBER_ME_IDLE" \
    -s "ssoSessionMaxLifespanRememberMe=$REMEMBER_ME_MAX"

  echo ">>> [03:$realm] WebAuthn policy (RpId, RpEntityName, required user verification)"
  kc update "realms/$realm" \
    -s 'webAuthnPolicyRpId="secforge.dev"' \
    -s "webAuthnPolicyRpEntityName=\"$rp_entity_name\"" \
    -s 'webAuthnPolicyUserVerificationRequirement="required"' \
    -s 'webAuthnPolicyAttestationConveyancePreference="none"' \
    -s 'webAuthnPolicyCreateTimeout=60' \
    -s 'webAuthnPolicySignatureAlgorithms=["ES256","RS256"]'

  echo ">>> [04:$realm] Custom $flow_alias flow (copy of browser, modify per realm)"
  if kc get authentication/flows -r "$realm" | jq -e --arg a "$flow_alias" '.[] | select(.alias==$a)' >/dev/null; then
    echo "    flow $flow_alias already exists — skipping copy"
  else
    echo "    copying built-in 'browser' flow → $flow_alias"
    kc create "authentication/flows/browser/copy" -r "$realm" -s "newName=$flow_alias"

    if [[ "$remove_otp_from_flow" == "true" ]]; then
      echo "    locating OTP Form execution in the new flow (passkey-only realm)"
      OTP_EXEC_ID=$(kc get "authentication/flows/$flow_alias/executions" -r "$realm" \
        | jq -r '.[] | select(.providerId=="auth-otp-form") | .id // empty')
      if [[ -n "$OTP_EXEC_ID" ]]; then
        echo "    removing OTP Form execution ($OTP_EXEC_ID)"
        kc delete "authentication/executions/$OTP_EXEC_ID" -r "$realm"
      fi
    else
      echo "    keeping OTP Form in flow (TOTP is an alternative 2FA in this realm)"
    fi

    echo "    locating Conditional-2FA subflow alias for execution insertion"
    COND_2FA_ALIAS=$(kc get "authentication/flows/$flow_alias/executions" -r "$realm" \
      | jq -r '.[] | select(.displayName | test("Conditional 2FA"; "i")) | .displayName // empty' | head -1)
    if [[ -z "$COND_2FA_ALIAS" ]]; then
      echo "FATAL: could not locate Conditional 2FA subflow inside $flow_alias" >&2; exit 2
    fi

    echo "    adding WebAuthn Authenticator under '$COND_2FA_ALIAS'"
    kc create "authentication/flows/$COND_2FA_ALIAS/executions/execution" -r "$realm" \
      -s 'provider="webauthn-authenticator"'

    echo "    adding Recovery Authentication Code Form fallback"
    kc create "authentication/flows/$COND_2FA_ALIAS/executions/execution" -r "$realm" \
      -s 'provider="auth-recovery-authn-code-form"'

    echo "    marking both added authenticators as ALTERNATIVE"
    for prov in webauthn-authenticator auth-recovery-authn-code-form; do
      EID=$(kc get "authentication/flows/$flow_alias/executions" -r "$realm" \
        | jq -r --arg p "$prov" '.[] | select(.providerId==$p) | .id // empty')
      [[ -n "$EID" ]] && kc update "authentication/executions/$EID" -r "$realm" \
        -s 'requirement="ALTERNATIVE"'
    done
  fi

  echo ">>> [05:$realm] Bind realm browserFlow to $flow_alias"
  CURRENT_FLOW=$(kc get "realms/$realm" | jq -r .browserFlow)
  if [[ "$CURRENT_FLOW" != "$flow_alias" ]]; then
    kc update "realms/$realm" -s "browserFlow=\"$flow_alias\""
    echo "    bound (was: $CURRENT_FLOW)"
  else
    echo "    already bound — skipping"
  fi

  echo ">>> [06:$realm] Required actions: webauthn-register (defaultAction=$webauthn_register_default)"
  EXPECTED_WR="{\"enabled\":true,\"defaultAction\":$webauthn_register_default}"
  WA_STATE=$(kc get "authentication/required-actions/webauthn-register" -r "$realm" \
    | jq -r '{enabled, defaultAction} | tostring')
  if [[ "$WA_STATE" != "$EXPECTED_WR" ]]; then
    # priority=20: passkey registers BEFORE recovery codes (40) so it gets the
    # lower credential-priority slot and becomes the DEFAULT 2FA challenge.
    # Reversing this makes Keycloak prompt for recovery codes instead of the
    # passkey (incident 2026-06-03 — project_keycloak_credential_priority_inversion).
    kc update "authentication/required-actions/webauthn-register" -r "$realm" \
      -s 'enabled=true' -s "defaultAction=$webauthn_register_default" -s 'priority=20'
    echo "    set (was: $WA_STATE)"
  else
    echo "    already at expected state — skipping"
  fi

  echo ">>> [07:$realm] Required actions: CONFIGURE_TOTP defaultAction=false"
  if kc get "authentication/required-actions/CONFIGURE_TOTP" -r "$realm" 2>/dev/null \
       | jq -e '.defaultAction == true' >/dev/null; then
    kc update "authentication/required-actions/CONFIGURE_TOTP" -r "$realm" \
      -s 'defaultAction=false'
    echo "    cleared defaultAction (kept enabled so existing TOTP users still resolve)"
  else
    echo "    CONFIGURE_TOTP not defaultAction — skipping"
  fi

  echo ">>> [08:$realm] Required actions: CONFIGURE_RECOVERY_AUTHN_CODES (defaultAction=$recovery_codes_default)"
  EXPECTED_RC="{\"enabled\":true,\"defaultAction\":$recovery_codes_default}"
  RC_STATE=$(kc get "authentication/required-actions/CONFIGURE_RECOVERY_AUTHN_CODES" -r "$realm" \
    | jq -r '{enabled, defaultAction} | tostring')
  if [[ "$RC_STATE" != "$EXPECTED_RC" ]]; then
    # priority=40: recovery codes register AFTER the passkey (20) so they are
    # the fallback 2FA, not the default. See the webauthn-register block above.
    kc update "authentication/required-actions/CONFIGURE_RECOVERY_AUTHN_CODES" -r "$realm" \
      -s 'enabled=true' -s "defaultAction=$recovery_codes_default" -s 'priority=40'
    echo "    set (was: $RC_STATE)"
  else
    echo "    already at expected state — skipping"
  fi

  echo ""
  echo "── $realm final state ──"
  kc get "realms/$realm" | jq '{
    browserFlow,
    passwordPolicy,
    webAuthnPolicyRpId,
    webAuthnPolicyRpEntityName,
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
  echo "── $realm default required actions ──"
  kc get "authentication/required-actions" -r "$realm" \
    | jq '[.[] | select(.defaultAction == true) | .alias]'
}

# ─── Preflight (run once, both realms share the same image + auth) ────────

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

# ─── Dispatch to one or all realms ────────────────────────────────────────

TARGET="${1:-all}"

# Args order matches harden_realm():
#   realm  flow_alias                rp_name             idle  max    rmOtp    wReg    rec
harden_platform() {
  harden_realm "platform"         "browser-webauthn-required" "SecForge Platform" 900  28800 "true"  "true"  "true"
}

harden_tenants() {
  harden_realm "secforge-tenants" "browser-webauthn-optional" "SecForge"          1800 43200 "false" "false" "false"
}

case "$TARGET" in
  platform)
    harden_platform
    ;;
  secforge-tenants)
    harden_tenants
    ;;
  all)
    harden_platform
    harden_tenants
    ;;
  *)
    echo "Unknown realm '$TARGET'. Valid: platform, secforge-tenants, all (default)" >&2
    exit 2
    ;;
esac

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Hardening replay complete."
echo "════════════════════════════════════════════════════════════"
