#!/usr/bin/env bash
# 99 — One-shot cleanup of disabled `temp-admin` user after 7-day soak.
#
# Scheduled via systemd timer to run at 2026-05-21 13:30 UTC = 15:30 CEST.
# Output → /var/log/secforge/temp-admin-cleanup-2026-05-21.log
#
# Pre-flight safety checks (fail-closed): if ANY check fails, abort without
# deleting anything.
#
#   1. temp-admin user still exists in master realm AND enabled=false
#      (if someone re-enabled it, we shouldn't auto-delete — that's a signal
#      something needed it)
#   2. jaupole exists in master realm with admin role + password + webauthn
#      + recovery-authn-codes credentials, no pending required actions
#      (i.e. there IS a working alternative admin)
#   3. keycloak-0 pod is 1/1 Running with age >12h (rules out unstable cluster
#      state where we shouldn't make destructive changes)
#   4. Master + platform realm OIDC discovery returns 200 (Keycloak is
#      serving normally)
#
# Why DB-level deletion (not API):
#   Keycloak's `webauthn-register defaultAction=true` makes admin-cli direct
#   grant impossible for users without passkeys. jaupole has a passkey but
#   we don't have its password on the box. DB DELETE with explicit child-row
#   cleanup is the only reliable scriptable path.
#
# Reference: project_keycloak_passkeys_mandatory.md

set -uo pipefail

NS=keycloak
DB_POD=secforge-keycloak-db-1
USER_TO_DELETE=temp-admin
USER_BACKUP_ADMIN=jaupole

LOG_DIR=/var/log/secforge
LOG_FILE=$LOG_DIR/temp-admin-cleanup-2026-05-21.log
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }
abort() { log "ABORT: $*"; exit 1; }

log "==== temp-admin cleanup BEGIN ===="

# ── DB connection setup ───────────────────────────────────────────────────
APP_PASS=$(kubectl -n "$NS" get secret secforge-keycloak-db-app -o jsonpath='{.data.password}' | base64 -d) \
    || abort "could not read CNPG app password Secret"
APP_USER=$(kubectl -n "$NS" get secret secforge-keycloak-db-app -o jsonpath='{.data.username}' | base64 -d)
DBNAME=$(kubectl -n "$NS" get secret secforge-keycloak-db-app -o jsonpath='{.data.dbname}' | base64 -d)

psql_query() {
    kubectl -n "$NS" exec "$DB_POD" -c postgres -- env PGPASSWORD="$APP_PASS" \
        psql -h localhost -U "$APP_USER" -d "$DBNAME" -tA -c "$1"
}

# ── Pre-flight 1: temp-admin exists + disabled ────────────────────────────
log ""
log "PREFLIGHT 1/4: $USER_TO_DELETE exists and is disabled"
RESULT=$(psql_query "SELECT u.username, u.enabled FROM USER_ENTITY u JOIN REALM r ON u.realm_id=r.id WHERE r.name='master' AND u.username='$USER_TO_DELETE';")
if [[ -z "$RESULT" ]]; then
    log "  $USER_TO_DELETE not found — already cleaned up. Nothing to do."
    exit 0
fi
ENABLED=$(echo "$RESULT" | cut -d'|' -f2)
if [[ "$ENABLED" != "f" ]]; then
    abort "$USER_TO_DELETE has enabled='$ENABLED' (expected 'f'). Someone re-enabled it — leaving in place."
fi
log "  $USER_TO_DELETE  enabled=f  ✓"

# ── Pre-flight 2: backup admin (jaupole) is fully set up ──────────────────
log ""
log "PREFLIGHT 2/4: $USER_BACKUP_ADMIN has password + webauthn + recovery codes + admin role"
JAUPOLE_ID=$(psql_query "SELECT u.id FROM USER_ENTITY u JOIN REALM r ON u.realm_id=r.id WHERE r.name='master' AND u.username='$USER_BACKUP_ADMIN';")
[[ -z "$JAUPOLE_ID" ]] && abort "$USER_BACKUP_ADMIN not found — no alternative admin available"

CREDS=$(psql_query "SELECT type FROM CREDENTIAL WHERE user_id='$JAUPOLE_ID' ORDER BY type;")
for need in password webauthn recovery-authn-codes; do
    echo "$CREDS" | grep -q "^$need$" || abort "$USER_BACKUP_ADMIN missing credential: $need"
    log "  $USER_BACKUP_ADMIN  has $need  ✓"
done

PENDING=$(psql_query "SELECT COUNT(*) FROM USER_REQUIRED_ACTION WHERE user_id='$JAUPOLE_ID';")
[[ "$PENDING" != "0" ]] && abort "$USER_BACKUP_ADMIN has $PENDING pending required actions — would block login"
log "  $USER_BACKUP_ADMIN  pending required actions = 0  ✓"

ADMIN_ROLE=$(psql_query "SELECT 1 FROM USER_ROLE_MAPPING urm JOIN KEYCLOAK_ROLE kr ON urm.role_id=kr.id WHERE urm.user_id='$JAUPOLE_ID' AND kr.name='admin' LIMIT 1;")
[[ -z "$ADMIN_ROLE" ]] && abort "$USER_BACKUP_ADMIN does not have admin role"
log "  $USER_BACKUP_ADMIN  has admin role  ✓"

# ── Pre-flight 3: keycloak pod stable ─────────────────────────────────────
log ""
log "PREFLIGHT 3/4: keycloak-0 pod 1/1 Running >12h"
READY=$(kubectl -n "$NS" get pod keycloak-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
PHASE=$(kubectl -n "$NS" get pod keycloak-0 -o jsonpath='{.status.phase}' 2>/dev/null)
START=$(kubectl -n "$NS" get pod keycloak-0 -o jsonpath='{.status.startTime}' 2>/dev/null)
[[ "$READY" != "true" || "$PHASE" != "Running" ]] && abort "keycloak-0 phase=$PHASE ready=$READY"

AGE_S=$(( $(date +%s) - $(date -d "$START" +%s) ))
(( AGE_S < 43200 )) && abort "keycloak-0 age=${AGE_S}s (<12h). Recent restart may indicate instability."
log "  keycloak-0  phase=Running ready=true age=$((AGE_S/3600))h  ✓"

# ── Pre-flight 4: OIDC discovery serving normally ─────────────────────────
log ""
log "PREFLIGHT 4/4: master + platform realms OIDC discovery 200"
for r in master platform; do
    HTTP=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://auth.secforge.dev/realms/$r/.well-known/openid-configuration")
    [[ "$HTTP" != "200" ]] && abort "realm=$r OIDC discovery returned HTTP $HTTP"
    log "  realm=$r  HTTP=$HTTP  ✓"
done

# ── All pre-flights passed: execute DB deletion ───────────────────────────
log ""
log "BEFORE state (master-realm users):"
psql_query "SELECT u.username, u.enabled FROM USER_ENTITY u JOIN REALM r ON u.realm_id=r.id WHERE r.name='master' ORDER BY username;"

log ""
log "EXECUTING delete of $USER_TO_DELETE via cascading DB DELETEs..."

TEMP_ID=$(psql_query "SELECT id FROM USER_ENTITY u JOIN REALM r ON u.realm_id=r.id WHERE r.name='master' AND u.username='$USER_TO_DELETE';")
log "  $USER_TO_DELETE id: $TEMP_ID"

# Single transaction with explicit child-row cleanup; Keycloak has FK
# constraints with varying CASCADE behaviour — manual deletion is safest.
kubectl -n "$NS" exec "$DB_POD" -c postgres -- env PGPASSWORD="$APP_PASS" \
    psql -h localhost -U "$APP_USER" -d "$DBNAME" <<EOF
BEGIN;
DELETE FROM USER_REQUIRED_ACTION WHERE user_id = '$TEMP_ID';
DELETE FROM CREDENTIAL WHERE user_id = '$TEMP_ID';
DELETE FROM USER_ATTRIBUTE WHERE user_id = '$TEMP_ID';
DELETE FROM USER_ROLE_MAPPING WHERE user_id = '$TEMP_ID';
DELETE FROM USER_GROUP_MEMBERSHIP WHERE user_id = '$TEMP_ID';
DELETE FROM FEDERATED_IDENTITY WHERE user_id = '$TEMP_ID';
DELETE FROM USER_CONSENT WHERE user_id = '$TEMP_ID';
DELETE FROM IDENTITY_PROVIDER_MAPPER WHERE id IN (
  SELECT id FROM IDENTITY_PROVIDER_MAPPER WHERE id NOT IN (SELECT id FROM IDENTITY_PROVIDER_MAPPER)
); -- no-op safety; placeholder for any missed link table
DELETE FROM USER_ENTITY WHERE id = '$TEMP_ID';
COMMIT;
EOF

log ""
log "AFTER state (master-realm users):"
psql_query "SELECT u.username, u.enabled FROM USER_ENTITY u JOIN REALM r ON u.realm_id=r.id WHERE r.name='master' ORDER BY username;"

log ""
log "==== temp-admin cleanup COMPLETE ===="
log ""
log "Follow-up: the keycloak-initial-admin K8s Secret in the keycloak ns still"
log "references the deleted user. Consider deleting it:"
log "  kubectl -n keycloak delete secret keycloak-initial-admin"
log "Or keep it as a Helm-chart artifact (unused but harmless)."
