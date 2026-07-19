# Runbook: ecosystem-db restore drill

Proves the ecosystem-db backup chain (CNPG plugin base backups + WAL archiving
to MinIO, `s3://backups/cnpg/ecosystem-db`) actually restores — a completed
Backup object is not a tested restore. Run this **quarterly** and after any
major migration touching ecosystem-db (new database, schema overhaul, PG major
upgrade, MinIO/ObjectStore changes).

Cost: ~5 minutes wall clock, one temporary 20Gi PVC, no impact on prod.

## Known gotchas (both bit the first drill, 2026-07-19)

1. **`status.firstRecoverabilityPoint` is EMPTY on plugin-method clusters.**
   Do not read that as "no backups" (and do not read it as "backups fine"
   either) — with `barman-cloud.cloudnative-pg.io` plugin backups the field is
   not populated the way legacy `barmanObjectStore` clusters populate it
   (keycloak/spicedb show May 2026 values from their pre-plugin era). The only
   trustworthy signal is this drill.
2. **Namespace NetworkPolicies must select CNPG pods by label KEY, not the
   pinned prod cluster name.** `allow-egress-to-minio` and
   `allow-cnpg-operator-to-db` originally matched
   `cnpg.io/cluster: ecosystem-db` exactly; a restore cluster carries its own
   name label (`ecosystem-db-drill`), so its barman restore died on
   "Connection was closed before we received a valid response" against MinIO.
   Both policies now use `matchExpressions: {key: cnpg.io/cluster, operator:
   Exists}` (mirroring the minio-side `allow-cross-ns-minio-clients`
   selector). If a future drill fails with connection errors, check this
   class first — the same wall would block a REAL side-by-side DR restore.

## Procedure

1. Apply the drill cluster (ephemeral; do NOT commit it under manifests/):

```yaml
# SAFETY: no spec.plugins on this cluster — it must NEVER archive WALs.
# Only externalClusters carries the plugin reference, read-only.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ecosystem-db-drill
  namespace: ecosystem-db
  labels:
    secforge.platform/component: restore-drill
spec:
  instances: 1
  imageName: <copy .spec.imageName from the live ecosystem-db Cluster>
  storage:
    size: 20Gi
    storageClass: local-path
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: "1",  memory: 1Gi }
  bootstrap:
    recovery:
      source: ecosystem-db-origin
  externalClusters:
    - name: ecosystem-db-origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: minio-backup
          serverName: ecosystem-db
```

2. Wait for `Cluster in healthy state`:
   `kubectl -n ecosystem-db get cluster ecosystem-db-drill -w`

3. Validate — compare the 3 largest tables per database against prod:

```bash
for db in control member_hub proposal_forge business_manager project_manager; do
  echo "== $db"
  for t in $(kubectl -n ecosystem-db exec ecosystem-db-1 -c postgres -- \
      psql -U postgres -d $db -Atc \
      "SELECT schemaname||'.'||relname FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 3"); do
    P=$(kubectl -n ecosystem-db exec ecosystem-db-1 -c postgres -- psql -U postgres -d $db -Atc "SELECT count(*) FROM $t")
    D=$(kubectl -n ecosystem-db exec ecosystem-db-drill-1 -c postgres -- psql -U postgres -d $db -Atc "SELECT count(*) FROM $t")
    printf '  %-45s prod=%-8s drill=%-8s %s\n' $t $P $D $([ "$P" = "$D" ] && echo OK || echo DIFF)
  done
done
```

   Expected: everything OK except high-write tables, which lag by the WAL
   archiving window. `control.onlyoffice_usage_samples` (fed by a per-minute
   cron) is the built-in RPO ruler: rows-behind ≈ minutes of unarchived WAL.

4. Tear down (deletes the PVC with it):
   `kubectl -n ecosystem-db delete cluster ecosystem-db-drill`

## Drill log

| Date | Restore time | Validation | Demonstrated RPO | Notes |
|------|--------------|------------|------------------|-------|
| 2026-07-19 | 2m25s to healthy | 14/15 top tables exact | ~3 min (onlyoffice_usage_samples 3 rows behind) | First drill. Exposed the exact-label NetworkPolicy wall (fixed same day); data ~85MB across 6 DBs. |
