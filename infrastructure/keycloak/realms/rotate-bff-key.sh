#!/usr/bin/env bash
# rotate-bff-key.sh — rotate ONE BFF client's private_key_jwt keypair.
# Phase 7d.1.a; runbook: docs/03-runbooks/bff-key-rotation.md.
#
# What this does (single-key atomic swap, no JWKS overlap window):
#   1. Generates a fresh RSA-2048 keypair locally.
#   2. Pre-flight: client exists in Keycloak (secforge-tenants realm),
#      OpenBao path readable, BFF Deployment exists in `app` ns.
#   3. Writes new private_pem + public_pem as a new KV-v2 version at
#      secret/data/keycloak/clients/<client_id>.
#   4. Reads the current Keycloak client JSON, sets the
#      `attributes."jwt.credential.public.key"` value to the new public
#      key (bare base64), and PUTs the modified representation back. All
#      other attributes (DPoP, PKCE, PAR, PS256, …) are preserved as-is.
#   5. Rolling-restarts the BFF Deployment in the `app` ns; the new pod
#      reloads the new private key from OpenBao at startup.
#   6. Waits for rollout to complete; failure = exit non-zero.
#
# Why single-key (no overlap):
#   Phase 6.10b bootstrap-bff-clients.sh registers the client public key
#   via the single-value attribute `jwt.credential.public.key`
#   (with use.jwks.url=false and use.jwks.string=false). Multi-key JWKS
#   would require switching to use.jwks.string=true plus a JWKS-document
#   shape — a scheme change out of scope for Phase 7d. The cost of the
#   single-key shape is brief BFF unavailability between the Keycloak
#   attribute update (step 4) and the BFF pod becoming Ready again
#   (step 5). For 90-day rotation cadence on local edition this is
#   acceptable; runbook documents the operator behavior.
#
# Idempotent: re-running mid-flight is safe.
#   - Step 3: KV-v2 versions automatically (each run = new version).
#   - Step 4: kcadm update with full JSON is idempotent.
#   - Step 5: kubectl rollout restart is idempotent.
#
# Auth (host-side run):
#   Caller exports BAO_TOKEN to a token with capabilities:
#     - read on secret/data/keycloak/clients/kcadm-admin
#       (used by _lib/kcadm-auth.sh to fetch kcadm-admin's client_secret)
#     - create+update on secret/data/keycloak/clients/<client-id>
#     - read on secret/metadata/keycloak/clients/<client-id>
#
#   The CronJob version (Phase 7d.1.b) sets BAO_TOKEN via SPIFFE→OpenBao
#   `auth/jwt/login` before invoking this script — the script itself is
#   transport-agnostic about how BAO_TOKEN was obtained.
#
# Output: structured JSON to STDOUT (one line per step). Promtail picks
# these up via the standard pod-log scrape and Loki labels them with the
# pod's app=rotate-bff-key label (set on the CronJob pod template).
#
# These events use the discriminator `bff.key.rotation.<step|success|failed>`
# — a separate schema from the secrets-events-collector's
# `secrets.guardrail.bypass` events. Rotation is an operational event,
# not a guardrail bypass; the existing kube-state-metrics
# CronJob-failure rule covers Alertmanager routing on failure.
#
# Usage:
#   BAO_TOKEN=hvs.xxxx bash infrastructure/keycloak/realms/rotate-bff-key.sh <client-id>
#
# Where <client-id> is one of:
#   helloworld-bff, proposal-forge-bff, project-tracker-bff, pm-bff

set -euo pipefail

# ─── Arg parse ──────────────────────────────────────────────────────────
CLIENT_ID="${1:-}"
case "$CLIENT_ID" in
    helloworld-bff|proposal-forge-bff|project-tracker-bff|pm-bff) ;;
    *)
        printf '{"ts":"%s","severity":"error","event":"bff.key.rotation.failed","step":"arg-parse","msg":"unknown or missing client_id","arg":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CLIENT_ID}" >&2
        printf 'Usage: BAO_TOKEN=hvs.xxx %s <client-id>\n' "$0" >&2
        printf 'Where <client-id> is one of: helloworld-bff, proposal-forge-bff, project-tracker-bff, pm-bff\n' >&2
        exit 64
        ;;
esac

APP_NS=app
KC_NS=keycloak
KC_POD=keycloak-0
BAO_NS=openbao
BAO_POD=openbao-0
KC_REALM=secforge-tenants

# ─── kcadm-admin auth (sourced helper) ──────────────────────────────────
# Default: relative path matching the on-repo layout. The CronJob version
# (Phase 7d.1.b) overrides via KCADM_AUTH_HELPER because ConfigMap mounts
# are flat — both scripts live in the same /scripts directory in-pod.
KCADM_AUTH_HELPER="${KCADM_AUTH_HELPER:-$(dirname "$0")/../_lib/kcadm-auth.sh}"
# shellcheck source=../_lib/kcadm-auth.sh
. "$KCADM_AUTH_HELPER"

# ─── Structured logging (one JSON line per call) ────────────────────────
log_step() {
    # log_step <severity> <step> [extra-jq-object-string]
    # severity ∈ {info, success, error}; defaults to {} for extras.
    local severity="$1" step="$2"
    local extra="${3:-{\}}"
    local ev
    case "$severity" in
        error)   ev="bff.key.rotation.failed" ;;
        success) ev="bff.key.rotation.success" ;;
        info|*)  ev="bff.key.rotation.step" ;;
    esac
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn \
        --arg severity "$severity" \
        --arg event "$ev" \
        --arg step "$step" \
        --arg client_id "$CLIENT_ID" \
        --arg phase "7d.1" \
        --arg ts "$ts" \
        --argjson extra "$extra" \
        '{ts:$ts, severity:$severity, event:$event, step:$step, client_id:$client_id, phase:$phase} + $extra'
}

die() {
    # die <step> [extra-jq-object-string] [exit-code]
    local step="$1"; shift
    local extra="${1:-{\}}"; [ $# -gt 0 ] && shift
    local code="${1:-1}"
    log_step error "$step" "$extra" >&2
    exit "$code"
}

# ─── 1. Pre-flight ──────────────────────────────────────────────────────
log_step info preflight-start

# 1a. BAO_TOKEN required.
if [ -z "${BAO_TOKEN:-}" ]; then
    die preflight '{"reason":"BAO_TOKEN env var not set"}'
fi

# 1b. kcadm authentication. Helper fetches kcadm-admin's client_secret
#     from OpenBao at secret/keycloak/clients/kcadm-admin and authenticates
#     kcadm.sh to the master realm in the keycloak-0 pod. Cached session
#     is reused by subsequent kcadm() calls in this run.
kcadm_admin_auth || die preflight '{"reason":"kcadm-admin auth failed (see _lib/kcadm-auth.sh hints above)"}'

kcadm() {
    kubectl exec -n "$KC_NS" "$KC_POD" -c keycloak -- /opt/keycloak/bin/kcadm.sh "$@"
}

# 1c. Resolve internal Keycloak client UUID. The update endpoint takes
#     the internal id, not the clientId-name.
KC_INT_ID=$(kcadm get clients -r "$KC_REALM" -q "clientId=${CLIENT_ID}" \
        --fields id --format csv --noquotes 2>/dev/null \
        | tr -d '\r' | head -1 || true)
if [ -z "$KC_INT_ID" ]; then
    die preflight "{\"reason\":\"client ${CLIENT_ID} not found in realm ${KC_REALM}\"}"
fi

# 1d. BFF Deployment must exist (rolling-restart needs a real target).
if ! kubectl get deployment -n "$APP_NS" "$CLIENT_ID" >/dev/null 2>&1; then
    die preflight "{\"reason\":\"deployment ${APP_NS}/${CLIENT_ID} not found — is the BFF deployed yet? CronJobs for un-deployed BFFs should remain suspend:true\"}"
fi

# 1e. OpenBao path must be readable with the supplied token.
if ! kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao kv metadata get -mount=secret "keycloak/clients/${CLIENT_ID}" >/dev/null 2>&1; then
    die preflight "{\"reason\":\"openbao path secret/data/keycloak/clients/${CLIENT_ID} inaccessible (token capabilities? path missing?)\"}"
fi

log_step info preflight-passed "{\"kc_internal_id\":\"${KC_INT_ID}\"}"

# ─── 2. Generate fresh RSA-2048 keypair ─────────────────────────────────
log_step info generate-keypair

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
chmod 700 "$TMPDIR"

(umask 077; openssl genrsa -out "$TMPDIR/private.pem" 2048 2>/dev/null)
openssl rsa -in "$TMPDIR/private.pem" -pubout -out "$TMPDIR/public.pem" 2>/dev/null

PRIV_PEM=$(cat "$TMPDIR/private.pem")
PUB_PEM=$(cat "$TMPDIR/public.pem")
# Bare base64 PEM body (no headers, no newlines) — matches what the
# bootstrap script writes to the same Keycloak attribute.
PUB_BARE=$(printf '%s' "$PUB_PEM" | sed -e '/^-----BEGIN/d' -e '/^-----END/d' | tr -d '\n')

# ─── 3. Write KV-v2 version ─────────────────────────────────────────────
log_step info kv-write

ROTATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KV_JSON=$(jq -cn \
    --arg priv "$PRIV_PEM" \
    --arg pub "$PUB_PEM" \
    --arg cid "$CLIENT_ID" \
    --arg src "phase-7d-rotation" \
    --arg ts "$ROTATED_AT" \
    '{private_pem:$priv, public_pem:$pub, client_id:$cid, source:$src, rotated_at:$ts}')

# Stage payload inside openbao-0 /tmp; never via env var (would surface
# in the pod's process list and be visible to anyone with `kubectl exec`).
KV_JSON_PATH="/tmp/rotate-${CLIENT_ID}-$$.json"
kubectl exec -i -n "$BAO_NS" "$BAO_POD" -c openbao -- \
    sh -c "umask 077; cat > $KV_JSON_PATH" <<<"$KV_JSON"

if ! kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
        bao kv put -mount=secret "keycloak/clients/${CLIENT_ID}" "@${KV_JSON_PATH}" >/dev/null 2>&1; then
    kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_JSON_PATH" >/dev/null 2>&1 || true
    die kv-write '{"reason":"bao kv put failed"}'
fi
kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- rm -f "$KV_JSON_PATH" >/dev/null 2>&1 || true

NEW_VERSION=$(kubectl exec -n "$BAO_NS" "$BAO_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv metadata get -format=json -mount=secret "keycloak/clients/${CLIENT_ID}" 2>/dev/null \
    | jq -r '.data.current_version')

log_step info kv-write-complete "{\"kv_version\":${NEW_VERSION}}"

# ─── 4. Update Keycloak client public-key attribute ─────────────────────
# Read current client JSON, modify just the one attribute, write back.
# Preserves DPoP/PKCE/PAR/PS256 and other attributes set by Phase 6.10b
# bootstrap. kcadm '-s' with dotted attribute keys has parser ambiguity;
# full-JSON update is the same idiom the bootstrap uses.
log_step info kc-attribute-update

# Pull current client JSON. Strip CR (kubectl exec on Linux pod from
# Windows host's WSL can produce stray \r in some pipes — defensive).
CURRENT_CLIENT_JSON=$(kcadm get "clients/${KC_INT_ID}" -r "$KC_REALM" 2>/dev/null | tr -d '\r')
if [ -z "$CURRENT_CLIENT_JSON" ]; then
    die kc-attribute-update '{"reason":"failed to read current client JSON from kcadm"}'
fi

MODIFIED_CLIENT_JSON=$(printf '%s' "$CURRENT_CLIENT_JSON" \
    | jq --arg pk "$PUB_BARE" '.attributes["jwt.credential.public.key"] = $pk')

KC_JSON_PATH="/tmp/rotate-client-${CLIENT_ID}-$$.json"
kubectl exec -i -n "$KC_NS" "$KC_POD" -c keycloak -- \
    sh -c "umask 077; cat > $KC_JSON_PATH" <<<"$MODIFIED_CLIENT_JSON"

if ! kcadm update "clients/${KC_INT_ID}" -r "$KC_REALM" -f "$KC_JSON_PATH" >/dev/null 2>&1; then
    kubectl exec -n "$KC_NS" "$KC_POD" -c keycloak -- rm -f "$KC_JSON_PATH" >/dev/null 2>&1 || true
    die kc-attribute-update '{"reason":"kcadm update failed (see kcadm STDERR via kubectl logs / kubectl exec)"}'
fi
kubectl exec -n "$KC_NS" "$KC_POD" -c keycloak -- rm -f "$KC_JSON_PATH" >/dev/null 2>&1 || true

log_step info kc-attribute-update-complete

# ─── 5. Rolling-restart the BFF Deployment ──────────────────────────────
# Step 4 already moved Keycloak to the new public key — assertions signed
# with the OLD private key are now rejected. Until the BFF pod restarts
# and reloads the new private key from OpenBao, the BFF returns 5xx. The
# rolling restart minimizes the window.
log_step info bff-rollout-start

if ! kubectl rollout restart -n "$APP_NS" "deployment/${CLIENT_ID}" >/dev/null 2>&1; then
    die bff-rollout-start '{"reason":"kubectl rollout restart failed"}'
fi

# 180s timeout: covers init container (wait-for-spiffe-csi) + spiffe-helper
# + first OpenBao read + http listener + readiness probe. Generous to
# accommodate cold cluster CPU throttling.
if ! kubectl rollout status -n "$APP_NS" "deployment/${CLIENT_ID}" --timeout=180s >/dev/null 2>&1; then
    die bff-rollout-status '{"reason":"BFF rollout did not complete in 180s; manual intervention needed (see runbook § Rollback)"}'
fi

log_step info bff-rollout-complete

# ─── 6. Done ────────────────────────────────────────────────────────────
log_step success rotation-complete "{\"kv_version\":${NEW_VERSION},\"rotated_at\":\"${ROTATED_AT}\"}"
