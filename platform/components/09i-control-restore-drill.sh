#!/usr/bin/env bash
# 09i — CNPG restore drill for control-db (one-shot, NOT idempotent — re-runs
#       delete-and-recreate). The control-plane sibling of 09g (Keycloak).
#
# Purpose: prove the control-db barman restore path works END-TO-END *and*
# that a restore PRESERVES the FORCE-RLS posture (audit EC-003 / SC-3.4 / R4,
# cutover 2026-06-02). Restores `control-db` from its latest barman backup into
# a fresh `verify-restore-control` namespace, then runs the posture gate
# (verify-control-force-rls-posture.sql) against the recovered DB, then tears
# down.
#
# What it proves (beyond 09g's "blobs intact + WAL replays"):
#   1. The restored control DB has FORCE ROW LEVEL SECURITY on every RLS table.
#   2. Ownership came back as control_owner (NOT the pre-cutover `control`).
#   3. control is non-super / non-bypassrls and owns none of the RLS tables.
#   4. org_isolation + exempt_read (061) policies survived.
#   5. FORCE actually binds `control` at runtime; control_reader can read the
#      exempt tables (functional, via SET ROLE).
#
# This is the control-db answer to security rule 41 ("an untested backup is a
# wish"). Run it quarterly per docs/03-runbooks/README.md, after any change to
# the control backup config, and after the next ownership-model change.
#
# Roles come from the BACKUP (global catalog, captured by pg_basebackup), so the
# drill does NOT need OpenBao/VSO: the posture gate uses SET ROLE from the
# in-pod superuser, exactly like ecosystem-control/scripts/validate-force-rls.mjs.
# (A REAL recovery still needs OpenBao up so control_migrator/control_reader can
#  AUTHENTICATE — see docs/03-runbooks/control-db-restore.md for that ordering.)
#
# Pre-conditions:
#   - control-db Cluster healthy in the control ns
#   - At least one Completed Backup exists (a POST-cutover one to prove the new
#     posture; a pre-cutover backup would correctly FAIL the gate)
#   - MinIO running; cnpg-minio-credentials Secret present in the control ns
#
# Tear-down: at end of script (or Ctrl-C) the verify ns + cluster are deleted.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

NS_SOURCE=control
NS_VERIFY=verify-restore-control
SOURCE_CLUSTER=control-db
RESTORED_CLUSTER=restored-control-db
SERVER_NAME=control-db-pg17                 # barman serverName (PG17 timeline)
DEST_PATH=s3://backups/cnpg/control
POSTURE_SQL="$SCRIPT_DIR/verify-control-force-rls-posture.sql"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

cleanup() {
  yellow "==> tearing down verify environment"
  kubectl delete ns "$NS_VERIFY" --ignore-not-found --wait=false 2>&1 | tail -3 || true
}
trap cleanup EXIT

[ -f "$POSTURE_SQL" ] || { red "ERROR: posture gate not found: $POSTURE_SQL"; exit 1; }

# Pre-check: at least one completed backup exists.
LATEST_BACKUP=$(kubectl -n "$NS_SOURCE" get backup.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[?(@.status.phase=="completed")]}{.metadata.name}{"\n"}{end}' | tail -1)
if [ -z "$LATEST_BACKUP" ]; then
  red "ERROR: no completed Backup CR found in $NS_SOURCE"; exit 1
fi
green "==> using source backup: $LATEST_BACKUP"
yellow "    NOTE: if this backup predates the 2026-06-02 cutover, the posture"
yellow "    gate SHOULD fail (pre-cutover = control-owned, no FORCE). That is a"
yellow "    correct result, not a drill bug — see control-db-restore.md."

# 1. Fresh ns (restricted PSA, same as 09g).
green "==> create fresh namespace $NS_VERIFY"
kubectl delete ns "$NS_VERIFY" --ignore-not-found --wait=true 2>&1 | tail -3 || true
kubectl create ns "$NS_VERIFY" \
  --dry-run=client -o yaml | \
  kubectl label --local --dry-run=client -f - \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted \
    platform.platform/purpose=restore-drill \
    -o yaml | kubectl apply -f -

# 2. Copy the MinIO credentials Secret across namespaces (CNPG/barman reads the
#    backup blobs with these; SSE-S3 decryption is transparent on MinIO's side).
green "==> copy cnpg-minio-credentials Secret to $NS_VERIFY"
kubectl -n "$NS_SOURCE" get secret cnpg-minio-credentials -o json | \
  jq '.metadata |= {name, labels} | .metadata.namespace = "'"$NS_VERIFY"'"' | \
  kubectl apply -f -

# 3. Apply the restored Cluster CR (one instance — drill, not HA). No
#    managed.roles: every role is recovered from the backup's global catalog.
green "==> apply restored Cluster CR (recovery from $LATEST_BACKUP)"
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RESTORED_CLUSTER
  namespace: $NS_VERIFY
  labels:
    platform.platform/purpose: restore-drill
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6-bookworm
  storage:
    size: 5Gi
  bootstrap:
    recovery:
      source: $SOURCE_CLUSTER
      database: control
      owner: control
  externalClusters:
    - name: $SOURCE_CLUSTER
      barmanObjectStore:
        serverName: $SERVER_NAME
        destinationPath: $DEST_PATH
        endpointURL: http://minio.minio.svc.cluster.local:9000
        s3Credentials:
          accessKeyId:
            key: ACCESS_KEY_ID
            name: cnpg-minio-credentials
          secretAccessKey:
            key: ACCESS_SECRET_KEY
            name: cnpg-minio-credentials
        wal:
          compression: gzip
        data:
          compression: gzip
EOF

# 4. Wait for the restore to complete (up to 10 min — see 09g notes on the
#    operator status-sync lag and the egress-NetworkPolicy failure mode).
green "==> waiting for $RESTORED_CLUSTER to become ready"
for i in $(seq 1 120); do
  STATUS=$(kubectl -n "$NS_VERIFY" get cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  READY=$(kubectl -n "$NS_VERIFY" get cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
  echo "  [$i] phase=$STATUS readyInstances=$READY"
  if [ "$STATUS" = "Cluster in healthy state" ] && [ "$READY" = "1" ]; then
    green "    cluster healthy after $((i*5))s"
    break
  fi
  if [ "$i" -eq 120 ]; then
    red "ERROR: cluster did not become healthy within 10 min"
    kubectl -n "$NS_VERIFY" describe cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" | tail -30
    exit 1
  fi
  sleep 5
done

# 5. Run the FORCE-RLS posture gate against the restored DB (as the in-pod
#    superuser via the local socket; -v ON_ERROR_STOP=1 makes the first failed
#    assertion exit non-zero).
green "==> running FORCE-RLS posture gate against the restored control DB"
PRIMARY=$(kubectl -n "$NS_VERIFY" get pods -l "cnpg.io/cluster=$RESTORED_CLUSTER,role=primary" -o jsonpath='{.items[0].metadata.name}')
green "    primary pod: $PRIMARY"

if kubectl -n "$NS_VERIFY" exec -i "$PRIMARY" -c postgres -- \
     psql -U postgres -d control -v ON_ERROR_STOP=1 -f - < "$POSTURE_SQL" 2>&1 | sed 's/^/    /'; then
  GATE=pass
else
  GATE=fail
fi

if [ "$GATE" != "pass" ]; then
  red "==> POSTURE GATE FAILED on the restored control DB."
  red "    Either the source backup predates the cutover (re-apply 060+061 on a"
  red "    real recovery — see control-db-restore.md), or the restore lost"
  red "    ownership/FORCE/policy state. This is the failure the drill exists to catch."
  exit 1
fi

cat <<EOF

✓ control-db restore drill PASSED.

  Source cluster:    $NS_SOURCE/$SOURCE_CLUSTER
  Source backup:     $LATEST_BACKUP
  Restored cluster:  $NS_VERIFY/$RESTORED_CLUSTER (1 instance)
  Posture gate:      PASS (FORCE + control_owner ownership + policies + functional)

  This proves:
    - control-db backup blobs in MinIO are intact + WAL replays
    - a restore PRESERVES the FORCE-RLS posture (rule 41 satisfied for control)
    - control_owner ownership, FORCE on every RLS table, org_isolation +
      exempt_read policies, and control/control_reader behaviour all survive

  Verify ns will be deleted on script exit (trap).
EOF
