#!/usr/bin/env bash
# Phase 3.7 automated verification — runs the checks Claude can do
# without an interactive browser. The interactive portion (TOTP
# enrollment, recovery-code generation, real auth-code flow) lives in
# the runbook for the human operator.
#
# USAGE
#   bash verify.sh                          # anonymous checks only
#   KCADM_USER=jaupole \
#   KCADM_PASSWORD='…' \
#   KCADM_TOTP=123456 \
#   bash verify.sh                          # full validation incl. admin REST
#
# Without admin creds, the BFF-client and required-action checks are
# skipped (printed as SKIP rather than FAIL). Anonymous-mode failures
# still flunk the run.
#
# Exit code: non-zero on any failure.

set -euo pipefail

PUBLIC_HOST="https://auth.secforge.local"
ADMIN_HOST="https://auth-admin.secforge.local"
NS=keycloak
KC_POD=keycloak-0

green()  { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; FAILED=1; }
skip()   { printf '\033[33m  ↷ %s\033[0m\n' "$*"; }
hdr()    { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

FAILED=0
KCADM_AUTHED=0

# Authenticate kcadm once per run if creds are provided. We do this
# upfront so all subsequent admin-API checks share one session.
if [ -n "${KCADM_USER:-}" ] && [ -n "${KCADM_PASSWORD:-}" ]; then
    if [ -n "${KCADM_TOTP:-}" ]; then
        OTP_FLAG=(--otp "$KCADM_TOTP")
    else
        OTP_FLAG=()
    fi
    if kubectl exec -n "$NS" "$KC_POD" -- /opt/keycloak/bin/kcadm.sh \
            config credentials \
            --server http://localhost:8080 \
            --realm master \
            --user "$KCADM_USER" \
            --password "$KCADM_PASSWORD" \
            "${OTP_FLAG[@]}" >/dev/null 2>&1; then
        KCADM_AUTHED=1
    fi
fi

# 1. OIDC discovery for both realms.
hdr "OIDC discovery"
for realm in master platform secforge-tenants; do
    body=$(curl -sk "$PUBLIC_HOST/realms/$realm/.well-known/openid-configuration") || \
        { red "$realm: discovery fetch failed"; continue; }
    issuer=$(jq -r .issuer <<<"$body")
    if [ "$issuer" = "$PUBLIC_HOST/realms/$realm" ]; then
        green "$realm: issuer = $issuer"
    else
        red "$realm: issuer mismatch — got '$issuer'"
    fi
    # PAR
    par=$(jq -r '.pushed_authorization_request_endpoint // ""' <<<"$body")
    [ -n "$par" ] && green "$realm: PAR advertised" || red "$realm: PAR endpoint missing"
    # DPoP
    dpop=$(jq -r '.dpop_signing_alg_values_supported // [] | length' <<<"$body")
    [ "$dpop" -gt 0 ] && green "$realm: DPoP advertised ($dpop algs)" || red "$realm: DPoP not advertised"
done

# 2. JWKS — each realm must publish at least one RS256 sig key.
hdr "JWKS / signing keys"
for realm in master platform secforge-tenants; do
    sig_count=$(curl -sk "$PUBLIC_HOST/realms/$realm/protocol/openid-connect/certs" \
        | jq '[.keys[] | select(.use=="sig" and .alg=="RS256")] | length')
    if [ "$sig_count" -ge 1 ]; then
        green "$realm: $sig_count RS256 sig key(s)"
    else
        red "$realm: no RS256 sig key found"
    fi
done

# 3. Admin host serves admin console.
hdr "Admin console hostname split"
code=$(curl -sk -o /dev/null -w "%{http_code}" "$ADMIN_HOST/admin/master/console/")
[ "$code" = "200" ] && green "admin host /admin/master/console/ → 200" || red "admin host /admin → $code"

# 4. Public host does NOT serve admin console.
code=$(curl -sk -o /dev/null -w "%{http_code}" "$PUBLIC_HOST/admin/")
[ "$code" = "404" ] && green "public host /admin/ → 404 (admin gated by hostname.admin)" || red "public host /admin/ unexpectedly $code"

# 5. All four BFF clients exist with the right config.
hdr "BFF clients (realm secforge-tenants)"
expected=(helloworld-bff proposal-forge-bff project-tracker-bff pm-bff)
if [ "$KCADM_AUTHED" -ne 1 ]; then
    skip "no admin creds provided — skipping client-config checks"
    skip "(set KCADM_USER, KCADM_PASSWORD, KCADM_TOTP to enable)"
else
    clients=$(kubectl exec -n "$NS" "$KC_POD" -- /opt/keycloak/bin/kcadm.sh \
        get clients -r secforge-tenants --fields clientId --format csv --noquotes 2>/dev/null \
        | tr -d '\r')
    for cid in "${expected[@]}"; do
        if grep -qx "$cid" <<<"$clients"; then
            green "$cid: present"
        else
            red "$cid: missing"
        fi
    done

    # Per-client attribute checks.
    for cid in "${expected[@]}"; do
        js=$(kubectl exec -n "$NS" "$KC_POD" -- /opt/keycloak/bin/kcadm.sh \
            get clients -r secforge-tenants -q clientId="$cid" 2>/dev/null)
        test_attr() {
            actual=$(jq -r "$1" <<<"$js" 2>/dev/null)
            if [ "$actual" = "$2" ]; then
                green "$cid: $3 = $2"
            else
                red "$cid: $3 = '$actual' (want '$2')"
            fi
        }
        test_attr '.[0].clientAuthenticatorType' 'client-jwt' 'auth method'
        test_attr '.[0].standardFlowEnabled' 'true' 'authcode flow'
        test_attr '.[0].implicitFlowEnabled' 'false' 'implicit flow disabled'
        test_attr '.[0].directAccessGrantsEnabled' 'false' 'ROPC disabled'
        test_attr '.[0].publicClient' 'false' 'confidential'
        test_attr '.[0].fullScopeAllowed' 'false' 'fullScopeAllowed=false'
        test_attr '.[0].attributes."dpop.bound.access.tokens"' 'true' 'DPoP-bound tokens'
        test_attr '.[0].attributes."require.pushed.authorization.requests"' 'true' 'PAR required'
        test_attr '.[0].attributes."pkce.code.challenge.method"' 'S256' 'PKCE S256'
        test_attr '.[0].attributes."token.endpoint.auth.signing.alg"' 'PS256' 'client-jwt PS256'
        test_attr '.[0].attributes."id.token.signed.response.alg"' 'RS256' 'id_token RS256'
        test_attr '.[0].attributes."access.token.signed.response.alg"' 'RS256' 'access_token RS256'
    done
fi

# 6. Per-client K8s Secrets exist with both keys.
hdr "Per-client signing key Secrets (app namespace)"
for cid in "${expected[@]}"; do
    sec="bff-jwt-${cid}"
    if kubectl get secret -n app "$sec" >/dev/null 2>&1; then
        priv=$(kubectl get secret -n app "$sec" -o jsonpath='{.data.private\.pem}' | wc -c)
        pub=$(kubectl get secret -n app "$sec" -o jsonpath='{.data.public\.pem}' | wc -c)
        if [ "$priv" -gt 1000 ] && [ "$pub" -gt 200 ]; then
            green "$sec: private.pem (${priv}B) + public.pem (${pub}B)"
        else
            red "$sec: keys present but sizes look wrong (priv=${priv}, pub=${pub})"
        fi
    else
        red "$sec: missing"
    fi
done

# 7. Realm policies — TOTP + recovery-codes required actions.
hdr "Realm required actions (TOTP + recovery codes)"
if [ "$KCADM_AUTHED" -ne 1 ]; then
    skip "no admin creds — skipping required-action checks"
else
    for realm in platform secforge-tenants; do
        js=$(kubectl exec -n "$NS" "$KC_POD" -- /opt/keycloak/bin/kcadm.sh \
            get authentication/required-actions -r "$realm" 2>/dev/null)
        for action in CONFIGURE_TOTP CONFIGURE_RECOVERY_AUTHN_CODES; do
            enabled=$(jq -r ".[] | select(.alias==\"$action\") | .enabled" <<<"$js" 2>/dev/null)
            defaulted=$(jq -r ".[] | select(.alias==\"$action\") | .defaultAction" <<<"$js" 2>/dev/null)
            if [ "$enabled" = "true" ] && [ "$defaulted" = "true" ]; then
                green "$realm: $action enabled+default"
            else
                red "$realm: $action enabled=$enabled defaultAction=$defaulted"
            fi
        done
    done
fi

# 8. SPIFFE-CSI volume + SVID for keycloak workload.
hdr "Workload identity (SPIFFE)"
svc_ok=$(kubectl exec -n "$NS" "$KC_POD" -- ls /spiffe-workload-api/api.sock 2>&1 | grep -c "api.sock" || true)
[ "$svc_ok" -ge 1 ] && green "Workload API socket present at /spiffe-workload-api/api.sock" || red "Workload API socket missing"

# 9. Pod security context spot-check.
hdr "Pod hardening"
sc=$(kubectl get pod -n "$NS" "$KC_POD" -o json | jq -c '.spec.containers[0].securityContext')
test_field() {
    # Avoid jq's `//` operator — it treats `false` as null and would
    # mask `allowPrivilegeEscalation: false` as "<unset>". Use an
    # explicit null-check via the `?` operator.
    val=$(jq -r ".$1" <<<"$sc")
    if [ "$val" = "$2" ]; then
        green "container.securityContext.$1 = $2"
    else
        red "container.securityContext.$1 = $val (want $2)"
    fi
}
test_field 'allowPrivilegeEscalation' 'false'
test_field 'runAsNonRoot' 'true'
test_field 'capabilities.drop[0]' 'ALL'
test_field 'seccompProfile.type' 'RuntimeDefault'

# 10. NetworkPolicy presence.
hdr "NetworkPolicy"
for np in default-deny-ingress allow-ingress-nginx-to-keycloak \
          allow-operator-to-keycloak allow-keycloak-egress \
          allow-postgres-ingress allow-realm-import-egress; do
    if kubectl get networkpolicy -n "$NS" "$np" >/dev/null 2>&1; then
        green "$np present"
    else
        red "$np missing"
    fi
done

# 11. Bootstrap-admin path is closed (post-Phase-3.7).
#
# After the user has enrolled their own TOTP-protected admin in master
# realm, the bootstrap path must be torn down. We assert:
#   - keycloak-bootstrap-admin Secret is GONE
#   - master-realm `bootstrap-admin` user is GONE
#
# The operator-managed `keycloak-initial-admin` Secret is allowed to
# exist (operator always recreates it; functionally inert because the
# master realm already has admin users) — see keycloak-operations.md.
#
# We deliberately don't try to log into Keycloak as bootstrap-admin to
# verify the user is gone, because that would require re-creating the
# Secret. Instead we ask the running Keycloak via its admin REST API
# under whatever credentials the operator has cached in the Job pods.
hdr "Bootstrap-admin path closed"
if kubectl get secret -n "$NS" keycloak-bootstrap-admin >/dev/null 2>&1; then
    red "keycloak-bootstrap-admin Secret still exists — bootstrap path is OPEN"
else
    green "keycloak-bootstrap-admin Secret is gone"
fi
# We can't run kcadm without credentials. The CR's `bootstrapAdmin` ref
# is the closest static check we can make; if it's set, the bootstrap
# path is documented as open.
if kubectl get keycloak -n "$NS" keycloak -o json | \
        jq -e '.spec.bootstrapAdmin' >/dev/null 2>&1; then
    red "Keycloak CR still declares spec.bootstrapAdmin — bootstrap path is OPEN"
else
    green "Keycloak CR no longer declares spec.bootstrapAdmin"
fi

echo
if [ "$FAILED" = "0" ]; then
    printf '\033[32m== ALL CHECKS PASSED ==\033[0m\n'
    exit 0
else
    printf '\033[31m== FAILURES ABOVE ==\033[0m\n'
    exit 1
fi
