# Runbook — MinIO Version Upgrade

> Upgrade the in-cluster MinIO server (and the `mc` client image used by the
> bucket-bootstrap Job) to a newer release. Single-node standalone deployment
> only — Operator migration is a separate procedure.

## When to use

- A new MinIO release closes a CVE that affects our usage.
- Routine cadence (target: at least every ~6 months) to stay near upstream.
- An upgrade is a prerequisite for a piece of work that depends on a newer
  feature/fix (e.g. Member Hub joining the cluster, where MinIO is the
  substrate for its CNPG barman backups).

## What you're upgrading

| Pin | Where | Form |
|---|---|---|
| MinIO server image | `platform/values/minio.yaml` (`image.repository` / `image.tag`) | Helm value override that the chart honors |
| `mc` client image | `platform/manifests/minio/02-bucket-bootstrap-job.yaml` | Direct `image:` line, ideally `@sha256:...` |
| Helm chart version (rarely) | `platform/components/07a-minio.sh` (`CHART_VER`) | Bash variable — Renovate's customManager (`renovate.json`) tracks this; you usually accept its PR rather than editing by hand |

The chart `minio/minio` v5.4.0 is currently the **last published standalone
chart** — MinIO has effectively shifted further development to the MinIO
Operator. For our single-node setup, that's fine: we override the chart's
default image with a newer tag, leaving the chart at 5.4.0.

## What you're NOT upgrading (and when to revisit)

- **Migrate off MinIO entirely** — tracked separately (see operator-backlog
  item for the strategic concern: as of Sep 2025 MinIO stopped publishing
  new public AGPL release images; security fixes after that point only
  ship as `.hotfix` backports of older releases for paying customers).
- **Migrate to MinIO Operator** — not applicable for single-node bare-metal.
- **Velero kopia backend off MinIO** — currently a circular dependency
  (Velero stores its kopia repo in `backups/velero` *inside* the MinIO it
  protects). That's why this runbook takes an out-of-band filesystem
  snapshot before touching the image.

## Pre-flight checklist

- [ ] `ssh secforge` works, `sudo -n kubectl` works on the box.
- [ ] No Velero backup in flight:
      `sudo -n kubectl -n velero get backup --no-headers | awk '{print $2}' | grep -E '^(InProgress|New)$' || echo OK`
- [ ] Host has free space ≥ 2× current MinIO data size on the MinIO
      partition: `df -h /var/lib/minio` (target: < 50% used after the
      snapshot doubles it). Today's data is ~28 GiB on a 250 GiB partition,
      so plenty of headroom.
- [ ] Maintenance window of ~15 minutes secured. During the snapshot +
      rolling restart, writes to MinIO pause (consumers retry on their own,
      but in-flight observability data may be lost — Tempo / Loki buffer
      briefly, no permanent loss).
- [ ] Pin target tags resolved + digests captured (record below before
      you start):

  ```
  MinIO server tag:    RELEASE.YYYY-MM-DDTHH-MM-SSZ
  MinIO server digest: sha256:____
  mc client tag:       RELEASE.YYYY-MM-DDTHH-MM-SSZ
  mc client digest:    sha256:____
  ```

  Resolve via: `docker buildx imagetools inspect quay.io/minio/minio:<tag>
  --format '{{.Manifest.Digest}}'` from any machine with Docker.

## Step 1 — Snapshot the MinIO data dir

The Velero kopia repo lives INSIDE MinIO; a Velero restore can't recover
MinIO data. We take a filesystem-level copy of the static PV first.

```bash
SNAP_TAG="$(date -u +%Y-%m-%dT%H%M%SZ)"
ssh secforge "
  set -e
  echo '>>> scaling minio to 0 to quiesce writes'
  sudo -n kubectl -n minio scale deploy/minio --replicas=0
  sudo -n kubectl -n minio wait --for=delete pod -l app=minio --timeout=120s
  echo '>>> copying /var/lib/minio/data -> /var/lib/minio/data.pre-upgrade-${SNAP_TAG}'
  sudo cp -a /var/lib/minio/data /var/lib/minio/data.pre-upgrade-${SNAP_TAG}
  echo '>>> snapshot size:'
  sudo du -sh /var/lib/minio/data.pre-upgrade-${SNAP_TAG}
"
```

Record the snapshot directory name; you'll need it for rollback / cleanup.

## Step 2 — Commit the new image pins

Edit `platform/values/minio.yaml` — add an `image:` block at the top of
the values (after the existing comments):

```yaml
# Image override — pinned by digest so cosign-style supply-chain checks
# still have something to verify. Resolve digest each upgrade via:
#   docker buildx imagetools inspect quay.io/minio/minio:<tag> --format '{{.Manifest.Digest}}'
# See docs/03-runbooks/minio-version-upgrade.md.
image:
  repository: quay.io/minio/minio
  tag: RELEASE.YYYY-MM-DDTHH-MM-SSZ
  pullPolicy: IfNotPresent
mcImage:
  repository: quay.io/minio/mc
  tag: RELEASE.YYYY-MM-DDTHH-MM-SSZ
  pullPolicy: IfNotPresent
```

Edit `platform/manifests/minio/02-bucket-bootstrap-job.yaml` — bump the
`image:` line to the new mc tag + digest:

```yaml
image: quay.io/minio/mc:RELEASE.YYYY-MM-DDTHH-MM-SSZ@sha256:____
```

Commit + push (the commit message should call out the CVE / reason if any
and reference the runbook).

## Step 3 — Apply

```bash
ssh secforge "
  set -e
  cd ~/secforge && git pull --ff-only
  echo '>>> re-running 07a-minio.sh (idempotent helm upgrade + bucket Job)'
  sudo bash platform/components/07a-minio.sh
  echo '>>> scaling minio back to 1 if helm did not'
  sudo -n kubectl -n minio scale deploy/minio --replicas=1 || true
  sudo -n kubectl -n minio rollout status deploy/minio --timeout=240s
"
```

## Step 4 — Verify

Run each of these; all should pass before you call the upgrade done.

```bash
ssh secforge '
  echo "--- pod ready + new image ---"
  sudo -n kubectl -n minio get pod -l app=minio -o jsonpath="{.items[0].spec.containers[0].image}{\"\n\"}"

  echo "--- SSE-S3 still active on backups bucket ---"
  ROOT=$(sudo -n kubectl -n minio get secret minio-root-credentials -o jsonpath="{.data.rootPassword}" | base64 -d)
  USR=$(sudo -n kubectl -n minio get secret minio-root-credentials -o jsonpath="{.data.rootUser}" | base64 -d)
  sudo -n kubectl -n minio exec deploy/minio -- sh -c "
    mc alias set L http://localhost:9000 $USR $ROOT >/dev/null
    mc encrypt info L/backups
    echo --- buckets ---
    mc ls L/
    echo --- sample read ---
    mc cat L/openbao-snapshots/ 2>&1 | head -c 32 || true
  "
'
```

End-to-end consumer verification (each must succeed on the new MinIO):

```bash
# Velero kopia → MinIO: one-shot backup of a small namespace
ssh secforge "sudo -n kubectl create -n velero -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: post-minio-upgrade-$(date +%s)
  namespace: velero
spec:
  includedNamespaces: [keycloak]
  defaultVolumesToFsBackup: true
EOF"

# Wait for Phase=Completed; if Phase=PartiallyFailed or Failed, ABORT and
# go to rollback.
ssh secforge 'sudo -n kubectl -n velero get backup -o wide --sort-by=.metadata.creationTimestamp | tail -3'

# CNPG barman → MinIO: trigger an on-demand backup of control-db
ssh secforge "sudo -n kubectl create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: post-minio-upgrade-$(date +%s)
  namespace: control
spec:
  cluster: { name: control-db }
EOF"

# Wait for Phase=completed
ssh secforge 'sudo -n kubectl -n control get backup -o wide --sort-by=.metadata.creationTimestamp | tail -3'
```

Spot-check the observability writers (Tempo / Loki / Wazuh) are still
producing — quick check is "no crashlooping pod in the observability ns
in the 10 min after the upgrade":

```bash
ssh secforge 'sudo -n kubectl -n observability get pods'
```

## Step 5 — Soak + cleanup

Leave the snapshot in place for **at least 7 days** to give time for any
delayed-failure mode (e.g. a consumer that breaks only on next-week's
scheduled write) to surface. After the soak, remove it to reclaim disk:

```bash
ssh secforge "sudo rm -rf /var/lib/minio/data.pre-upgrade-${SNAP_TAG}"
```

Open a follow-up to update this runbook with the actual MinIO version
the upgrade landed on (and to refresh the "next-target" version in the
operator-backlog entry).

## Rollback

If verification fails (pod won't start, SSE error, Velero backup
errors, CNPG backup errors):

```bash
ssh secforge "
  set -e
  echo '>>> scaling minio to 0'
  sudo -n kubectl -n minio scale deploy/minio --replicas=0
  sudo -n kubectl -n minio wait --for=delete pod -l app=minio --timeout=120s
  echo '>>> swapping data dir back to pre-upgrade snapshot'
  sudo mv /var/lib/minio/data /var/lib/minio/data.failed-upgrade-${SNAP_TAG}
  sudo mv /var/lib/minio/data.pre-upgrade-${SNAP_TAG} /var/lib/minio/data
  echo '>>> reverting repo changes'
  cd ~/secforge && git revert --no-edit HEAD && git push
  echo '>>> re-applying old image via 07a-minio.sh'
  sudo bash platform/components/07a-minio.sh
"
```

Then verify (Step 4 again) and write up what went wrong as a follow-up
on the backlog item.

## Risk register

| Risk | Mitigation |
|---|---|
| MinIO image upgrade corrupts on-disk format and the old image can't read it back | Step 1 filesystem snapshot, kept for 7 days; rollback restores byte-for-byte |
| `MINIO_KMS_SECRET_KEY` (the built-in single-key KMS we use for SSE-S3 on the `backups` bucket) silently removed in target release → existing encrypted objects unreadable | Pre-upgrade: confirm in the target release notes that the env var is still honored; current status (as of RELEASE.2025-09-07) is still supported (April 2025 release explicitly improved its handling). Long-term fix is migration to MinIO KES — separate work |
| Consumers (Velero, CNPG, Tempo, Loki, Wazuh) regress on a behavior change | Step 4 end-to-end checks before declaring done; rollback if any fails |
| `mc` client tag drifts ahead of server tag and breaks bucket-bootstrap | mc is generally back-compatible with older servers; bump both together as a rule |
| Upgrade lands on an image without the latest security patch because MinIO stopped publishing OSS release images | Acknowledged + tracked in the strategic-MinIO backlog item; this runbook installs the latest *available* public stable, not the latest source-released version |
