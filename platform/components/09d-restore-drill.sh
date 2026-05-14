#!/usr/bin/env bash
# 09d — Restore drill: verify Velero + CNPG backup pipelines actually restore.
#
# Run this quarterly (or after any major change to the backup config) so
# you trust your backups. Untested backups are theatre.
#
# What this does:
#
#   Test 1 — Velero round-trip:
#     1. Create a marker ConfigMap in the keycloak namespace with a
#        timestamp + random UUID.
#     2. Trigger an immediate Velero backup of the keycloak namespace.
#     3. Delete the marker.
#     4. Restore from the backup, scoped to ConfigMaps only.
#     5. Verify the marker is back with the same timestamp + UUID.
#
#   Test 2 — CNPG bootstrap-from-backup:
#     1. Create a `verify-restore` namespace.
#     2. Copy `cnpg-minio-credentials` Secret from keycloak ns
#        (re-extracts the values via kubectl create — no Secret reference
#        copying so we avoid owner-ref binding to the source cluster).
#     3. Create a recovery Cluster CR with
#          spec.bootstrap.recovery.source: secforge-keycloak-db
#          spec.externalClusters[0].barmanObjectStore: <same as source>
#        This pattern works cross-namespace: CNPG queries the S3 location
#        for the latest base backup. (`spec.bootstrap.recovery.backup.name`
#        only works if the Backup CR lives in the recovery cluster's
#        namespace, which it doesn't.)
#     4. Wait for the cluster to come up.
#     5. Connect via psql, verify the recovered keycloak schema is intact
#        (count realms, list tables).
#     6. Tear down.
#
# Pre-conditions:
#   - 09a-velero.sh + 09b-cnpg-backups.sh deployed.
#   - At least one CNPG keycloak Backup is in `completed` state.
#   - MinIO `allow-cross-ns-minio-clients` NetworkPolicy includes
#     `verify-restore` in its cnpg.io/cluster ingress block (already
#     done in source manifest).
#
# Idempotent. Safe to re-run; the `verify-restore` namespace is dropped
# at the end.

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── Test 1: Velero round-trip ────────────────────────────────────────
green "==> Test 1: Velero ConfigMap round-trip"

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TEST_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
BK_NAME=restore-drill-$(date -u +%Y%m%d-%H%M%S)

green "    1. create marker ConfigMap (stamp=$STAMP, test_id=$TEST_ID)"
kubectl -n keycloak create configmap restore-drill-marker \
  --from-literal=stamp="$STAMP" \
  --from-literal=test-id="$TEST_ID" --dry-run=client -o yaml | kubectl apply -f -

green "    2. trigger Velero backup of keycloak ns"
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $BK_NAME
  namespace: velero
  labels:
    secforge.platform/purpose: restore-drill
spec:
  includedNamespaces: [keycloak]
  includeClusterResources: false
  snapshotVolumes: false
  defaultVolumesToFsBackup: false
  ttl: 24h0m0s
EOF

for i in $(seq 1 24); do
  PHASE=$(kubectl -n velero get backups.velero.io "$BK_NAME" -o jsonpath="{.status.phase}" 2>/dev/null || true)
  [ "$PHASE" = "Completed" ] && break
  [ "$PHASE" = "Failed" ] && { red "Velero backup Failed"; kubectl -n velero describe backups.velero.io "$BK_NAME" | tail -10; exit 1; }
  sleep 5
done
green "    backup Completed"

green "    3. delete marker"
kubectl -n keycloak delete configmap restore-drill-marker

green "    4. restore from backup (configmaps only)"
RES_NAME=restore-drill-from-$(date -u +%H%M%S)
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $RES_NAME
  namespace: velero
  labels:
    secforge.platform/purpose: restore-drill
spec:
  backupName: $BK_NAME
  includedResources: [configmaps]
  includedNamespaces: [keycloak]
EOF

for i in $(seq 1 24); do
  PHASE=$(kubectl -n velero get restore "$RES_NAME" -o jsonpath="{.status.phase}" 2>/dev/null || true)
  [ "$PHASE" = "Completed" ] && break
  sleep 5
done
green "    restore Completed"

green "    5. verify marker is back"
GOT_STAMP=$(kubectl -n keycloak get cm restore-drill-marker -o jsonpath='{.data.stamp}' 2>/dev/null || true)
GOT_TEST_ID=$(kubectl -n keycloak get cm restore-drill-marker -o jsonpath='{.data.test-id}' 2>/dev/null || true)

if [ "$GOT_STAMP" = "$STAMP" ] && [ "$GOT_TEST_ID" = "$TEST_ID" ]; then
  green "    ✓ Velero round-trip PASSED"
else
  red "FAIL: marker mismatch. expected stamp=$STAMP test-id=$TEST_ID, got stamp=$GOT_STAMP test-id=$GOT_TEST_ID"
  exit 1
fi

# Cleanup test artifacts
kubectl -n keycloak delete cm restore-drill-marker
kubectl -n velero delete backup.velero.io "$BK_NAME"
kubectl -n velero delete restore "$RES_NAME"

# ─── Test 2: CNPG bootstrap-from-backup ───────────────────────────────
green ""
green "==> Test 2: CNPG bootstrap-from-backup"

green "    1. create verify-restore namespace"
kubectl create ns verify-restore --dry-run=client -o yaml | kubectl apply -f -

green "    2. extract cnpg-minio-credentials values + recreate in verify-restore"
AK=$(kubectl -n keycloak get secret cnpg-minio-credentials -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
SK=$(kubectl -n keycloak get secret cnpg-minio-credentials -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)
kubectl -n verify-restore create secret generic cnpg-minio-credentials \
  --from-literal=ACCESS_KEY_ID="$AK" \
  --from-literal=ACCESS_SECRET_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f -
unset AK SK

green "    3. create recovery Cluster CR (uses externalClusters + recovery.source)"
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: secforge-keycloak-db-restored
  namespace: verify-restore
  labels:
    secforge.platform/component: cloudnativepg
    secforge.platform/purpose: restore-drill
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-bookworm
  storage:
    size: 5Gi
    storageClass: local-path
  bootstrap:
    recovery:
      source: secforge-keycloak-db
  externalClusters:
    - name: secforge-keycloak-db
      barmanObjectStore:
        destinationPath: s3://backups/cnpg/keycloak
        endpointURL: http://minio.minio.svc.cluster.local:9000
        s3Credentials:
          accessKeyId:
            name: cnpg-minio-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-minio-credentials
            key: ACCESS_SECRET_KEY
        wal:
          compression: gzip
        data:
          compression: gzip
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
EOF

green "    4. wait for cluster Ready (up to 10 min — recovery + WAL replay)"
for i in $(seq 1 60); do
  READY=$(kubectl -n verify-restore get cluster.postgresql.cnpg.io secforge-keycloak-db-restored -o jsonpath="{.status.readyInstances}" 2>/dev/null || true)
  PHASE=$(kubectl -n verify-restore get cluster.postgresql.cnpg.io secforge-keycloak-db-restored -o jsonpath="{.status.phase}" 2>/dev/null || true)
  [ "$READY" = "1" ] && break
  [ "$i" -eq 60 ] && { red "FAIL: cluster never became Ready (last phase=$PHASE)"; kubectl -n verify-restore get pods,jobs; exit 1; }
  sleep 10
done
green "    cluster Ready"

green "    5. verify recovered keycloak schema"
REALMS=$(kubectl -n verify-restore exec secforge-keycloak-db-restored-1 -c postgres -- \
  psql -U postgres -d keycloak -tAc 'SELECT count(*) FROM realm' 2>/dev/null | tr -d ' ' || true)
TABLES=$(kubectl -n verify-restore exec secforge-keycloak-db-restored-1 -c postgres -- \
  psql -U postgres -d keycloak -tAc "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public'" 2>/dev/null | tr -d ' ' || true)

green "    realms in recovered DB: $REALMS"
green "    public tables in recovered DB: $TABLES"

if [ -n "$REALMS" ] && [ "$REALMS" -ge 2 ] && [ -n "$TABLES" ] && [ "$TABLES" -ge 50 ]; then
  green "    ✓ CNPG recovery PASSED"
else
  red "FAIL: recovered DB doesn't look right. Expected ≥2 realms and ≥50 tables, got realms=$REALMS tables=$TABLES"
  exit 1
fi

green "    6. tear down verify-restore namespace"
kubectl delete ns verify-restore --wait=false

cat <<'EOF'

✓ Restore drill complete. Both pipelines validated.

Run quarterly (or after any change to:
  - components/09a-velero.sh, 09b-cnpg-backups.sh, 09c-velero-tune.sh
  - values/velero.yaml
  - manifests/minio/03-allow-cross-ns-clients.yaml
  - manifests/{keycloak,spicedb}/02-cnpg-cluster.yaml
)
EOF
