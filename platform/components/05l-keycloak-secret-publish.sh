#!/usr/bin/env bash
# 05l — Publish operator-auto-generated Keycloak client_secrets to their
#       consumer destinations (OpenBao kv for VSO-rendered consumers,
#       direct k8s Secret for the openbao client).
#
# Closes the greenfield half of backlog #60. Run AFTER:
#   - 03 / 03a have applied the platform-realm import (creates clients)
#   - 05a-05j have configured OpenBao (kv-v2 mounted, app roles bound)
#
# Idempotent (and the entire reason this works for the realistic Velero-
# restore DR scenario):
#
#   For each codified client:
#     1. Read CLIENT.secret directly from the Keycloak Postgres (CNPG
#        app password — the only auth path that works post-temp-admin-
#        delete; see project_keycloak_admin_db_only).
#     2. Read the current value at the destination (OpenBao kv field
#        or k8s Secret key).
#     3. If destination missing/empty: publish the Keycloak value.
#     4. If destination present and MATCHES Keycloak: no-op (the common
#        case on existing clusters AND on Velero-restored clusters).
#     5. If destination present but DIFFERS from Keycloak: WARN and
#        skip. Don't auto-resolve — drift could indicate an in-progress
#        rotation, a stale Velero restore, or a misconfiguration; an
#        operator should decide.
#
# Closes the greenfield-rebuild gap: realm-import creates clients with
# random secrets in the operator's Keycloak DB, but those values never
# flow to consumer apps without this script.
#
# Adding a new app: append a row to the CLIENT_DESTINATIONS table. Use
# `openbao://<mount>/<path>#<key>` for VSO consumers (preferred — VSO
# refresh propagates to consumer Secrets within 60s), or `k8s://<ns>/<secret-name>#<key>`
# for direct k8s Secrets (only when the consumer namespace can't run
# VSO — currently just the openbao ns since that secret feeds OpenBao's
# own OIDC auth config and using VSO there is circular).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# ─── Inputs ────────────────────────────────────────────────────────────────
KEYCLOAK_NS=keycloak
DB_POD=secforge-keycloak-db-1
KEYCLOAK_DB_SECRET=secforge-keycloak-db-app
REALM=platform

OPENBAO_NS=openbao
OPENBAO_POD=openbao-0

# ─── Domain (for ${DOMAIN}-substituted static fields) ─────────────────────
# Read from platform/globals.env when invoked directly; consumers via
# install-all.sh already have $DOMAIN exported.
if [ -z "${DOMAIN:-}" ]; then
  GLOBALS="$(dirname "$SCRIPT_DIR")/globals.env"
  if [ -f "$GLOBALS" ]; then
    # shellcheck disable=SC1090
    set -a; source "$GLOBALS"; set +a
  fi
fi
[ -z "${DOMAIN:-}" ] && { echo "FATAL: \$DOMAIN not set and platform/globals.env missing" >&2; exit 1; }

# ─── Static OIDC-bundle seeds (closes 07i's OpenBao side-effect) ──────────
# Some consumer apps need MORE than just the client_secret in their VSO-
# rendered Secret — e.g. wazuh-dashboard's OIDC bundle includes client_id,
# issuer, redirect_uri (for VSO templates), plus a session cookie_password
# that's NOT derived from Keycloak. These static fields must exist at the
# kv path BEFORE the publish loop adds the dynamic client_secret.
#
# Idempotency rule: only write each field if absent. cookie_password is
# generated randomly on first run and never regenerated (would invalidate
# every wazuh-dashboard session).
#
# Format: openbao_path|field|value_expression
#   value_expression literal text OR `random:<bytes>` to generate a fresh
#   base64-encoded random value (only on first run).
STATIC_SEEDS=(
  "secret/wazuh/oidc|client_id|wazuh-dashboard"
  "secret/wazuh/oidc|issuer|https://auth.${DOMAIN}/realms/platform"
  "secret/wazuh/oidc|redirect_uri|https://wazuh.${DOMAIN}/auth/openid/login"
  "secret/wazuh/oidc|cookie_password|random:32"
)

# ─── Client → destination table ───────────────────────────────────────────
# Format: client_id|destination_uri
#   openbao://<mount>/<path>#<key>     — VSO-rendered consumer
#   k8s://<ns>/<secret-name>#<key>     — direct k8s Secret (no VSO)
#   skip                               — public client (no secret)
CLIENT_DESTINATIONS=(
  "openbao|k8s://openbao/keycloak-openbao-client-secret#client_secret"
  "grafana|openbao://secret/grafana/oidc#client_secret"
  "wazuh-dashboard|openbao://secret/wazuh/oidc#client_secret"
  "control|openbao://secret/apps/control/runtime#oidc_client_secret"
  "control-admin|openbao://secret/apps/control/runtime#admin_client_secret"
  "control-portal|skip"
  "member-hub|openbao://secret/apps/member-hub/runtime#oidc_client_secret"
  "member-hub-admin|openbao://secret/apps/member-hub/runtime#admin_client_secret"
  "member-hub-system|openbao://secret/apps/member-hub/runtime#system_client_secret"
)

# ─── Helpers ───────────────────────────────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
gray()   { printf '\033[90m%s\033[0m\n' "$*"; }

mint_admin_token() {
  local sa_jwt
  sa_jwt=$(kubectl -n "$OPENBAO_NS" create token openbao \
    --audience=https://kubernetes.default.svc.cluster.local --duration=15m)
  kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -c openbao -- \
    env BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_SKIP_VERIFY=1 \
    bao write -format=json auth/kubernetes/login \
      role=admin-break-glass jwt="$sa_jwt" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])'
}

bao_admin() {
  local token=$1; shift
  kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -c openbao -- \
    env BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_SKIP_VERIFY=1 BAO_TOKEN="$token" \
    "$@"
}

kc_db_query() {
  local sql=$1
  kubectl -n "$KEYCLOAK_NS" exec "$DB_POD" -c postgres -- \
    env PGPASSWORD="$KC_DB_PASS" \
    psql -h localhost -U "$KC_DB_USER" -d "$KC_DB_NAME" -tA -c "$sql"
}

# Read CLIENT.secret column for a given client_id in the platform realm.
read_keycloak_client_secret() {
  local client_id=$1
  kc_db_query "SELECT c.secret FROM CLIENT c JOIN REALM r ON c.realm_id=r.id WHERE r.name='$REALM' AND c.client_id='$client_id';"
}

# Read OpenBao kv field. Echoes value (empty if missing).
read_openbao_field() {
  local token=$1 mount=$2 path=$3 key=$4
  bao_admin "$token" bao kv get -mount="$mount" -format=json "$path" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)['data']['data']
    print(d.get('$key', ''))
except: pass
"
}

# Write OpenBao kv field, preserving other keys at the same path. Merge-style.
write_openbao_field() {
  local token=$1 mount=$2 path=$3 key=$4 value=$5
  # Read existing data (may be empty).
  local existing_json
  existing_json=$(bao_admin "$token" bao kv get -mount="$mount" -format=json "$path" 2>/dev/null \
    || echo '{"data":{"data":{}}}')
  # Build merged JSON via python; base64-encode for safe transit through exec.
  local merged_b64
  merged_b64=$(EXISTING_JSON="$existing_json" KEY="$key" VALUE="$value" python3 <<'PYEOF'
import os, json, base64
try:
    existing = json.loads(os.environ["EXISTING_JSON"])
    data = existing.get("data", {}).get("data", {}) or {}
except Exception:
    data = {}
data[os.environ["KEY"]] = os.environ["VALUE"]
print(base64.b64encode(json.dumps(data).encode()).decode())
PYEOF
)
  bao_admin "$token" sh -c "echo $merged_b64 | base64 -d | bao kv put -mount=$mount $path -" \
    >/dev/null
}

# Read k8s Secret key value (base64-decoded, may be empty).
read_k8s_secret_field() {
  local ns=$1 name=$2 key=$3
  kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.$key}" 2>/dev/null \
    | { read -r b64; [ -n "$b64" ] && echo "$b64" | base64 -d || true; }
}

# Write k8s Secret key. Creates Secret if absent; patches the single key if present.
write_k8s_secret_field() {
  local ns=$1 name=$2 key=$3 value=$4
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    # Patch single field; preserves other keys via strategic-merge.
    local b64
    b64=$(printf '%s' "$value" | base64 -w0)
    kubectl -n "$ns" patch secret "$name" --type=merge \
      -p "{\"data\":{\"$key\":\"$b64\"}}" >/dev/null
  else
    kubectl -n "$ns" create secret generic "$name" --from-literal="$key=$value" >/dev/null
  fi
}

# ─── Pre-flight ────────────────────────────────────────────────────────────
echo ">>> Pre-flight: confirm Keycloak DB + OpenBao reachable"
KC_DB_USER=$(kubectl -n "$KEYCLOAK_NS" get secret "$KEYCLOAK_DB_SECRET" -o jsonpath='{.data.username}' | base64 -d)
KC_DB_PASS=$(kubectl -n "$KEYCLOAK_NS" get secret "$KEYCLOAK_DB_SECRET" -o jsonpath='{.data.password}' | base64 -d)
KC_DB_NAME=$(kubectl -n "$KEYCLOAK_NS" get secret "$KEYCLOAK_DB_SECRET" -o jsonpath='{.data.dbname}' | base64 -d)
kubectl -n "$KEYCLOAK_NS" exec "$DB_POD" -c postgres -- \
  env PGPASSWORD="$KC_DB_PASS" psql -h localhost -U "$KC_DB_USER" -d "$KC_DB_NAME" -tA -c "SELECT 1;" >/dev/null
gray "    Keycloak DB reachable as $KC_DB_USER@$KC_DB_NAME"

ADMIN_TOKEN=$(mint_admin_token)
[ -z "$ADMIN_TOKEN" ] && { red "FATAL: could not mint admin-break-glass token"; exit 1; }
gray "    OpenBao admin token minted via admin-break-glass (1h TTL)"

# ─── Phase 1: seed static OIDC-bundle metadata ─────────────────────────────
echo ""
echo ">>> Phase 1: static OIDC-bundle seeds (${#STATIC_SEEDS[@]} fields)"
SEEDED=0
SEED_SKIPPED=0
for row in "${STATIC_SEEDS[@]}"; do
  IFS='|' read -r SEED_PATH SEED_KEY SEED_VAL <<< "$row"
  # Split mount/path: path format here is `<mount>/<rest>`.
  SEED_MOUNT="${SEED_PATH%%/*}"
  SEED_KVPATH="${SEED_PATH#*/}"

  EXISTING=$(read_openbao_field "$ADMIN_TOKEN" "$SEED_MOUNT" "$SEED_KVPATH" "$SEED_KEY")
  if [ -n "$EXISTING" ]; then
    gray "    [seed-skip]    $SEED_PATH#$SEED_KEY  (already set, len=${#EXISTING})"
    SEED_SKIPPED=$((SEED_SKIPPED + 1))
    continue
  fi

  # Materialize value — handle `random:<N>` directive.
  if [[ "$SEED_VAL" == random:* ]]; then
    BYTES="${SEED_VAL#random:}"
    SEED_VAL=$(openssl rand -base64 "$BYTES" | tr -d '\n')
  fi

  write_openbao_field "$ADMIN_TOKEN" "$SEED_MOUNT" "$SEED_KVPATH" "$SEED_KEY" "$SEED_VAL"
  green "    [seeded]       $SEED_PATH#$SEED_KEY  (len=${#SEED_VAL})"
  SEEDED=$((SEEDED + 1))
done
echo "    seeded=$SEEDED  already-set=$SEED_SKIPPED"

# ─── Phase 2: reconcile each client → destination ──────────────────────────
echo ""
echo ">>> Phase 2: reconciling ${#CLIENT_DESTINATIONS[@]} clients"
PUBLISHED=0
SKIPPED_MATCH=0
SKIPPED_DRIFT=0
SKIPPED_PUBLIC=0
NOT_IN_KEYCLOAK=0

for row in "${CLIENT_DESTINATIONS[@]}"; do
  IFS='|' read -r CLIENT_ID DEST_URI <<< "$row"

  if [ "$DEST_URI" = "skip" ]; then
    gray "    [skip-public]  $CLIENT_ID  (public client, no secret)"
    SKIPPED_PUBLIC=$((SKIPPED_PUBLIC + 1))
    continue
  fi

  # Pull Keycloak's current value for this client.
  KC_VALUE=$(read_keycloak_client_secret "$CLIENT_ID" || true)
  if [ -z "$KC_VALUE" ]; then
    yellow "    [not-found]    $CLIENT_ID  (no row in CLIENT table — realm-import not done?)"
    NOT_IN_KEYCLOAK=$((NOT_IN_KEYCLOAK + 1))
    continue
  fi

  # Parse destination URI.
  if [[ "$DEST_URI" == openbao://* ]]; then
    # openbao://<mount>/<...path...>#<key>
    rest="${DEST_URI#openbao://}"
    DEST_MOUNT="${rest%%/*}"
    rest="${rest#*/}"
    DEST_PATH="${rest%#*}"
    DEST_KEY="${rest##*#}"
    EXISTING=$(read_openbao_field "$ADMIN_TOKEN" "$DEST_MOUNT" "$DEST_PATH" "$DEST_KEY")
    DEST_TYPE="openbao://$DEST_MOUNT/$DEST_PATH#$DEST_KEY"
  elif [[ "$DEST_URI" == k8s://* ]]; then
    # k8s://<ns>/<secret-name>#<key>
    rest="${DEST_URI#k8s://}"
    DEST_NS="${rest%%/*}"
    rest="${rest#*/}"
    DEST_SECRET="${rest%#*}"
    DEST_KEY="${rest##*#}"
    EXISTING=$(read_k8s_secret_field "$DEST_NS" "$DEST_SECRET" "$DEST_KEY")
    DEST_TYPE="k8s://$DEST_NS/$DEST_SECRET#$DEST_KEY"
  else
    red "    [bad-uri]      $CLIENT_ID  unparseable destination URI: $DEST_URI"
    continue
  fi

  if [ -z "$EXISTING" ]; then
    # No value at destination — publish from Keycloak.
    if [[ "$DEST_URI" == openbao://* ]]; then
      write_openbao_field "$ADMIN_TOKEN" "$DEST_MOUNT" "$DEST_PATH" "$DEST_KEY" "$KC_VALUE"
    else
      write_k8s_secret_field "$DEST_NS" "$DEST_SECRET" "$DEST_KEY" "$KC_VALUE"
    fi
    green "    [published]    $CLIENT_ID  →  $DEST_TYPE  (len=${#KC_VALUE})"
    PUBLISHED=$((PUBLISHED + 1))
  elif [ "$EXISTING" = "$KC_VALUE" ]; then
    gray "    [match]        $CLIENT_ID  =  $DEST_TYPE  (len=${#KC_VALUE})"
    SKIPPED_MATCH=$((SKIPPED_MATCH + 1))
  else
    yellow "    [DRIFT]        $CLIENT_ID  keycloak.len=${#KC_VALUE} dest.len=${#EXISTING} at $DEST_TYPE — leaving alone (investigate; use rotation runbook to resolve)"
    SKIPPED_DRIFT=$((SKIPPED_DRIFT + 1))
  fi
done

unset KC_DB_PASS
unset ADMIN_TOKEN

echo ""
echo "=== Summary ==="
echo "  Published (destination was empty):  $PUBLISHED"
echo "  Matched (no-op):                    $SKIPPED_MATCH"
echo "  Drift (left alone, investigate):    $SKIPPED_DRIFT"
echo "  Public clients (no secret):         $SKIPPED_PUBLIC"
echo "  Not in Keycloak (realm-import gap): $NOT_IN_KEYCLOAK"
echo ""
if [ "$SKIPPED_DRIFT" -gt 0 ]; then
  yellow "  Drift detected. See project_keycloak_client_secret_rotation_pattern"
  yellow "  for the right way to resolve (it includes the keycloak-0 cache-flush"
  yellow "  bounce that direct DB writes need)."
  exit 2
fi

green "✓ Secret publish complete."
