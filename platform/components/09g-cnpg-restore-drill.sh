#!/usr/bin/env bash
# 09g — CNPG restore drill (one-shot, NOT idempotent — re-runs delete-and-recreate).
#
# Purpose: prove the SSE-S3 + barmanObjectStore restore path actually
# works END-TO-END before we need it. Restores `platform-keycloak-db`
# from its latest barman backup into a fresh `verify-restore-keycloak`
# namespace, queries Keycloak realm tables, then tears down.
#
# What it proves:
#   1. MinIO SSE-S3 doesn't break barman read access (KMS env on MinIO
#      transparently decrypts).
#   2. Backup blobs are intact + parsable.
#   3. WAL replay works (point-in-time consistency).
#   4. Realm + user data is actually there post-restore.
#
# Pre-conditions:
#   - platform-keycloak-db Cluster healthy in keycloak ns
#   - At least one Completed Backup exists
#   - MinIO running with KMS key wired
#   - cnpg-minio-credentials Secret in keycloak ns (the source of creds
#     to copy to the verify ns)
#
# Tear-down: at end of script (or Ctrl-C) the verify ns + cluster are
# deleted. PVC cleanup follows ns deletion.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

NS_SOURCE=keycloak
NS_VERIFY=verify-restore
SOURCE_CLUSTER=platform-keycloak-db
RESTORED_CLUSTER=restored-keycloak-db

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

cleanup() {
  yellow "==> tearing down verify environment"
  kubectl delete ns "$NS_VERIFY" --ignore-not-found --wait=false 2>&1 | tail -3 || true
}
trap cleanup EXIT

# Pre-check: at least one completed backup exists.
LATEST_BACKUP=$(kubectl -n "$NS_SOURCE" get backup.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[?(@.status.phase=="completed")]}{.metadata.name}{"\n"}{end}' | tail -1)
if [ -z "$LATEST_BACKUP" ]; then
  red "ERROR: no completed Backup CR found in $NS_SOURCE"; exit 1
fi
green "==> using source backup: $LATEST_BACKUP"

# 1. Fresh ns.
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

# 2. Copy the MinIO credentials Secret across namespaces. (CNPG-side
# barman uses these to read backup blobs from MinIO. SSE-S3 decryption
# is transparent — the master key lives in MinIO's env, not here.)
green "==> copy cnpg-minio-credentials Secret to $NS_VERIFY"
# Strip ownerReferences (point to a resource in source ns), generated
# server-side fields, and re-namespace.
kubectl -n "$NS_SOURCE" get secret cnpg-minio-credentials -o json | \
  jq '.metadata |= {name, labels} | .metadata.namespace = "'"$NS_VERIFY"'"' | \
  kubectl apply -f -

# 3. Apply the restored Cluster CR (one instance — drill, not HA).
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
      database: keycloak
      owner: keycloak
  externalClusters:
    - name: $SOURCE_CLUSTER
      barmanObjectStore:
        serverName: $SOURCE_CLUSTER
        destinationPath: s3://backups/cnpg/keycloak
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

# 4. Wait for the restore to complete (up to 5 min).
green "==> waiting for $RESTORED_CLUSTER to become ready"
# Recovery Job completes in ~30s; primary pod start adds another minute;
# operator status sync after that ranges from seconds to a couple minutes.
# 10-minute window absorbs a flaky one without erroring; the average is
# much faster.
for i in $(seq 1 120); do
  STATUS=$(kubectl -n "$NS_VERIFY" get cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  READY=$(kubectl -n "$NS_VERIFY" get cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
  echo "  [$i] phase=$STATUS readyInstances=$READY"
  if [ "$STATUS" = "Cluster in healthy state" ] && [ "$READY" = "1" ]; then
    green "    cluster healthy after $((i*5))s"
    break
  fi
  # Specific failure mode after Layer A egress filtering: if readyInstances=1
  # but phase is "Instance Status Extraction Error: HTTP communication issue",
  # the postgres-operator can't reach the new primary's status :8000 endpoint.
  # That's the allow-egress-cnpg-instances NetworkPolicy missing or the
  # operator pod holding stale state — try `kubectl -n postgres-operator
  # rollout restart deploy/cnpg-cloudnative-pg`.
  if [ "$i" -eq 120 ]; then
    red "ERROR: cluster did not become healthy within 10 min"
    kubectl -n "$NS_VERIFY" describe cluster.postgresql.cnpg.io "$RESTORED_CLUSTER" | tail -30
    exit 1
  fi
  sleep 5
done

# 5. Verify Keycloak data is present + intact.
green "==> verifying keycloak realm data is intact"
PRIMARY=$(kubectl -n "$NS_VERIFY" get pods -l "cnpg.io/cluster=$RESTORED_CLUSTER,role=primary" -o jsonpath='{.items[0].metadata.name}')
green "    primary pod: $PRIMARY"

# Run a battery of sanity queries.
RESULT=$(kubectl -n "$NS_VERIFY" exec "$PRIMARY" -c postgres -- psql -U postgres -d keycloak -tAc "
  SELECT 'realms:'   || count(*) FROM realm
  UNION ALL
  SELECT 'users:'    || count(*) FROM user_entity
  UNION ALL
  SELECT 'clients:'  || count(*) FROM client
  UNION ALL
  SELECT 'sessions:' || count(*) FROM (SELECT 1 FROM information_schema.tables WHERE table_name='offline_user_session') t;
" 2>&1)
echo "$RESULT" | sed 's/^/    /'

REALMS=$(echo "$RESULT" | awk -F: '/^realms:/{print $2}')
USERS=$(echo "$RESULT"  | awk -F: '/^users:/{print $2}')
if [ -z "$REALMS" ] || [ "$REALMS" -lt 1 ]; then
  red "ERROR: expected at least 1 realm, got '$REALMS'"
  exit 1
fi
if [ -z "$USERS" ] || [ "$USERS" -lt 1 ]; then
  red "ERROR: expected at least 1 user, got '$USERS'"
  exit 1
fi

green "==> verify the platform realm specifically"
SECFORGE=$(kubectl -n "$NS_VERIFY" exec "$PRIMARY" -c postgres -- psql -U postgres -d keycloak -tAc \
  "SELECT name FROM realm WHERE name='platform';" 2>&1)
if [ "$SECFORGE" = "platform" ]; then
  green "    platform realm present"
else
  red "ERROR: platform realm MISSING from restored DB. Got: '$SECFORGE'"
  exit 1
fi

green "==> sample user emails from the restored platform realm (top 5)"
kubectl -n "$NS_VERIFY" exec "$PRIMARY" -c postgres -- psql -U postgres -d keycloak -tAc "
  SELECT u.email
    FROM user_entity u
    JOIN realm r ON u.realm_id=r.id
   WHERE r.name='platform'
   ORDER BY u.created_timestamp DESC
   LIMIT 5;
" 2>&1 | sed 's/^/    /'

cat <<EOF

✓ CNPG restore drill PASSED.

  Source cluster:    $NS_SOURCE/$SOURCE_CLUSTER
  Source backup:     $LATEST_BACKUP
  Restored cluster:  $NS_VERIFY/$RESTORED_CLUSTER (1 instance)
  Realms restored:   $REALMS
  Users restored:    $USERS
  platform realm:    present

  This proves:
    - MinIO SSE-S3 doesn't break CNPG/barman read access
    - Backup blobs in MinIO are intact + parsable
    - WAL replay works (cluster reached "healthy state")
    - Keycloak realm data is recoverable from backup

  Verify ns will be deleted on script exit (trap).
EOF
