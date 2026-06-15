# k3s datastore (SQLite/kine) backup & restore

This node's k3s datastore is **SQLite/kine** (`/var/lib/rancher/k3s/server/db/state.db`),
not etcd — so there are no `etcd-snapshot`s, and Velero captures k8s API objects, not the
datastore file. These snapshots give a lower-RPO, point-in-time datastore artifact for
**same-host rollback** (corruption, a bad bulk change). Backlog #95.

## What runs
- Script: `platform/scripts/k3s-datastore-backup.sh` (host, as root).
- Schedule: `platform/host/k3s-datastore-backup.cron` -> `/etc/cron.d/k3s-datastore-backup`,
  every 6h (Europe/Berlin) -> datastore RPO ~6h. Log `/var/log/k3s-datastore-backup.log`.
- Method: SQLite online backup API (`sqlite3 -readonly .backup`, consistent on a live WAL
  db) -> `integrity_check` gate -> gzip -> MinIO via SigV4 (stdlib python; the host has no
  aws/mc). 290MB DB -> ~64M object.
- Storage: MinIO bucket `k3s-datastore-backups`, **SSE-S3**, **7-day ILM expiry** (automatic
  retention, ~28 snapshots). Dedicated least-privilege MinIO user `k3s-db-backup` (policy
  `k3s-datastore-backup-rw`, locked to this bucket) — Velero's creds are scoped and cannot
  write here. Consumer creds: Secret `velero/k3s-datastore-backup-minio`.

## What is NOT included (important)
The k3s **secrets-encryption key** (`/var/lib/rancher/k3s/server/cred/encryption-config.json`)
is deliberately NOT shipped to object storage. So a snapshot restores cleanly **on this host**
(the key is already present). Restoring to a *different* host additionally needs that cred
file — and full-host-loss recovery is the Velero rebuild path
(`docs/03-runbooks/dr-drill-tier1-findings.md`), not this.

## List / fetch a snapshot
```bash
sudo bash platform/scripts/k3s-datastore-backup.sh list
sudo bash platform/scripts/k3s-datastore-backup.sh get <key> /tmp/state-restore.db.gz
```
Verify before trusting it:
```bash
sudo gunzip -f /tmp/state-restore.db.gz
sudo sqlite3 /tmp/state-restore.db "PRAGMA integrity_check;"   # expect: ok
sudo sqlite3 /tmp/state-restore.db "SELECT count(*) FROM kine;"
```

## Restore (same-host rollback) — DESTRUCTIVE, rolls the WHOLE cluster back
This reverts every k8s object to the snapshot point; anything created since is lost. Use only
for corruption or a bad bulk change. There is no live job dependency check — do it in a window.
```bash
# 0. fetch + verify the chosen snapshot to /tmp/state-restore.db (see above)
sudo systemctl stop k3s                                   # stop the datastore writer
sudo cp -a /var/lib/rancher/k3s/server/db/state.db \
           /var/lib/rancher/k3s/server/db/state.db.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)
sudo install -o root -g root -m 0644 /tmp/state-restore.db \
           /var/lib/rancher/k3s/server/db/state.db
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal \
           /var/lib/rancher/k3s/server/db/state.db-shm   # stale WAL would corrupt the new DB
sudo systemctl start k3s
# verify
sudo k3s kubectl get --raw=/readyz
sudo k3s kubectl get nodes
```
If the cluster does not come up, restore the pre-restore copy back over `state.db` (same
stop / replace / rm-wal-shm / start dance) and investigate.

After a successful restore, expect the single-node reboot-recovery items (openbao unseal,
ambient ztunnel/cni) per `docs/03-runbooks/openbao-seal-unseal.md` if k3s was down long.

## Re-provision the MinIO user/bucket (DR / key rotation)
The bucket + scoped user are created by `platform/manifests/minio/03-k3s-datastore-backup-credentials-job.yaml`.
To (re)create or rotate:
```bash
# 1. (re)generate the consumer Secret velero/k3s-datastore-backup-minio with a new
#    MINIO_ACCESS_KEY / MINIO_SECRET_KEY (and MINIO_BUCKET=k3s-datastore-backups)
# 2. copy it into the minio namespace as tmp-k3s-db-backup (same keys)
# 3. sudo k3s kubectl apply -f platform/manifests/minio/03-k3s-datastore-backup-credentials-job.yaml
# 4. sudo k3s kubectl delete secret tmp-k3s-db-backup -n minio
```
