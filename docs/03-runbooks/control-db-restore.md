# Runbook — control-db restore (FORCE-RLS aware)

> Audit ref: **EC-003 / SC-3.4 / R4**. Restores the control-plane Postgres
> (`control-db`, namespace `control`) from a barman backup **without losing the
> FORCE ROW LEVEL SECURITY posture** the 2026-06-02 cutover established. Pairs
> with [force-rls-cutover.md](./force-rls-cutover.md) (the one-time cutover) and
> [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md) (OpenBao DR).
>
> Last tested: **pending first 09i drill run** (the drill is committed; run
> `platform/components/09i-control-restore-drill.sh` to stamp this date).

## 1. Scope

Two scenarios:

- **Targeted recovery** — restore `control-db` into a replacement Cluster (data
  loss, corruption, a bad migration) while the rest of the platform stands.
- **Full-cluster-loss DR** — node/cluster rebuild, where the control DB restore
  is one step in an ORDERED sequence behind OpenBao.

The defining hazard, and why this is a separate runbook from the generic
restore drill: the control DB has a **split ownership model** (runtime role
`control` is non-owner / `NOBYPASSRLS`; `control_owner` owns the RLS tables;
`control_reader`/`control_migrator` are login roles whose passwords live in
OpenBao). A restore must bring that posture back intact, and a restore from a
**pre-cutover** backup will silently bring back the OLD, isolation-defeating
posture. Every path below ends at the **posture gate** (§5).

## 2. Prerequisites

- `kubectl` against the cluster; ability to `kubectl exec` into a CNPG primary.
- The barman coordinates for control-db (already in
  [06-objectstore.yaml](../../platform/manifests/control/06-objectstore.yaml)):
  serverName `control-db-pg17`, destinationPath `s3://backups/cnpg/control`,
  endpoint `http://minio.minio.svc.cluster.local:9000`, creds Secret
  `cnpg-minio-credentials` (keys `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`).
- For a **full DR**: OpenBao restorable per [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md)
  + [openbao-recovery.md](./openbao-recovery.md), and the Shamir threshold.
- The posture gate: `platform/components/verify-control-force-rls-posture.sql`.

## 3. What a physical restore DOES and DOES NOT bring back

CNPG/barman backups are **physical** (`pg_basebackup` + WAL). A physical restore
copies the whole data directory + global catalog, so these come back
**automatically and atomically**:

- table ownership (`pg_class.relowner` → `control_owner`),
- `FORCE ROW LEVEL SECURITY` (`pg_class.relforcerowsecurity`),
- the `org_isolation` + `exempt_read` policies (`pg_policy`),
- the role objects themselves incl. attributes + membership (`pg_authid`),
- grants, the audit-log hash-chain, sequences, functions, enums.

What a restore does **NOT** fix for you:

- **Role passwords / authentication.** `control_migrator` and `control_reader`
  authenticate with passwords sourced from OpenBao via VSO (Secrets
  `control-db-migrator`, `control-db-reader`); the app's reader path also fetches
  `secret/data/apps/control/db-reader` from OpenBao at runtime (ADR-0013). The
  backup carries the role rows but the live login chain depends on OpenBao + VSO
  being up. CNPG `managed.roles` reconciles role ATTRIBUTES (and re-applies
  passwords from those Secrets) after the operator manifests are applied —
  **this is why OpenBao must be restored before the app boots** (§4).
- **Posture correctness of an OLD backup.** A pre-2026-06-02 backup restores the
  pre-cutover posture faithfully — which is exactly wrong (§5, §6).

## 4. Full-cluster-loss DR ordering (do NOT reorder)

The control app **fails closed at boot** if OpenBao is unreachable
(`assertExemptReaderReachable` fetches `secret/data/apps/control/db-reader`,
retries, then `process.exit(1)`), and `control_migrator`/`control_reader` get
NULL passwords until VSO re-renders their Secrets. So:

1. **Restore + unseal OpenBao first** ([ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md);
   the whole-Raft snapshot already contains `secret/data/apps/control/*` and the
   `control` JWT policy — nothing control-specific to restore separately).
   Confirm: `bao kv get secret/apps/control/db-migrator` and `.../db-reader`
   resolve, and the `control` auth/jwt role exists.
2. **Apply the control manifests** (`platform/manifests/control/`) so CNPG +
   VSO come up. Confirm VSO rendered the Secrets:
   `kubectl -n control get secret control-db-migrator control-db-reader -o jsonpath='{.data.username}'`
   (both present).
3. **Restore control-db** via a recovery Cluster (§4a). `managed.roles`
   reconciles `control_owner`(NOLOGIN), `control_migrator`, `control_reader` and
   sets their passwords from the Secrets.
4. **Run the posture gate** (§5) against the restored DB — go/no-go.
5. **Run the migration Job** only if the restore point is behind HEAD (it picks
   up where `schema_migrations` left off; 061+ run as `control_owner`).
6. **Roll the app** last. Its boot gates (`assertForceRlsPosture` +
   `assertExemptReaderReachable`) are the final fail-closed backstop.

### 4a. Recovery Cluster manifest (copy-paste, edit the backup name)

> Apply this only during an actual recovery — do NOT pre-stage `bootstrap.recovery`
> in the live cluster config (CNPG anti-pattern). This mirrors the proven
> [09g](../../platform/components/09g-cnpg-restore-drill.sh) /
> [09i](../../platform/components/09i-control-restore-drill.sh) pattern. For
> PITR, add `recovery.recoveryTarget.targetTime` — but read §6 first.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: control-db                 # replace the lost cluster, or use a new name
  namespace: control
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6-bookworm
  storage: { size: 10Gi, storageClass: ${STORAGE_CLASS} }
  bootstrap:
    recovery:
      source: control-db-source
      database: control
      owner: control               # DB-level owner (datdba); tables are control_owner
  externalClusters:
    - name: control-db-source
      barmanObjectStore:
        serverName: control-db-pg17
        destinationPath: s3://backups/cnpg/control
        endpointURL: http://minio.minio.svc.cluster.local:9000
        s3Credentials:
          accessKeyId:     { name: cnpg-minio-credentials, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-minio-credentials, key: ACCESS_SECRET_KEY }
        wal:  { compression: gzip }
        data: { compression: gzip }
  # Re-add the live managed.roles + barman ScheduledBackup wiring from
  # platform/manifests/control/02-cnpg-cluster.yaml once recovered.
```

## 5. Validation — the posture gate (MANDATORY, go/no-go)

Run the posture gate as the in-pod superuser **before** routing the app at the
restored DB:

```bash
PRIMARY=$(kubectl -n control get pods -l 'cnpg.io/cluster=control-db,role=primary' -o jsonpath='{.items[0].metadata.name}')
kubectl -n control exec -i "$PRIMARY" -c postgres -- \
  psql -U postgres -d control -v ON_ERROR_STOP=1 -f - \
  < platform/components/verify-control-force-rls-posture.sql
```

It asserts (and exits non-zero on the first failure): `control` non-super /
non-bypassrls / owns no RLS table; `control_owner`(NOLOGIN) /
`control_reader` / `control_migrator`(member of both) exist; **every RLS table is
FORCE'd and owned by `control_owner`**; ≥21 FORCE'd tables (cutover baseline);
`audit_log` + `schema_migrations` owned by `control_owner`; `org_isolation` +
`exempt_read` policies present; and functionally that FORCE binds `control`
(0 rows with the sentinel org) and `control_reader` can read an exempt table.
A `PASS` line means it is safe to point the app at this DB.

Then confirm the app's own boot gates are green (it will CrashLoop if not):

```bash
kubectl -n control rollout restart deploy/control && kubectl -n control rollout status deploy/control
kubectl -n control logs deploy/control | grep -iE 'force-rls|exempt reader|listening'
```

## 6. Recovery — if the gate FAILS

- **`control owns N RLS table(s)` / `FORCE not binding` / count `< 21`** → you
  restored a **pre-cutover** backup (or a rolled-back one). Either choose a
  post-2026-06-02 backup, OR re-establish the posture on the restored DB by hand
  as the superuser: re-apply `060_force_rls_and_ownership.sql` (superuser) then
  `061_exempt_read_policies.sql` (`SET ROLE control_owner`) from the
  ecosystem-control repo, then re-run §5. Do **not** route the app until §5 is
  green — the boot gate would CrashLoop it anyway.
- **PITR note:** because WAL is archived continuously, recovering to a
  `targetTime` **after** the cutover reconstructs the post-cutover posture even
  if the most recent *base* backup predates it. Recovering to a target *before*
  the cutover is the failure case above. **Minimum safe recovery point is the
  2026-06-02 cutover** unless you intend to re-apply 060/061.
- **`no exempt_read policies` but other checks pass** → the 061 state was lost;
  re-apply `061_exempt_read_policies.sql` as `control_owner`, re-run §5. (The
  app boot gate would NOT have caught this — `withExemptRead` would break at
  first cross-org read.)
- **`control_reader`/`control_migrator` can't authenticate** (not the gate, but
  app boot) → OpenBao/VSO ordering (§4 steps 1–2) was skipped; ensure the
  Secrets are rendered, then `kubectl -n control delete pod` the CNPG primary to
  force a `managed.roles` reconcile.

## 7. Drill (rule 41 — "an untested backup is a wish")

`platform/components/09i-control-restore-drill.sh` restores the latest control-db
backup into a throwaway `verify-restore-control` ns, runs the §5 gate, and tears
down. It needs no OpenBao (roles come from the backup; the gate uses `SET ROLE`).
Run it **quarterly** (README cadence), after any control backup-config change,
and after the next ownership-model change. A pre-cutover source backup will
(correctly) fail the gate.

## 8. Cross-references

- [force-rls-cutover.md](./force-rls-cutover.md) — the one-time cutover + the
  060/061 migrations referenced in §6.
- [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md) — OpenBao backup/DR
  (the §4 step-1 dependency).
- ecosystem-control `src/api/db-assert.ts` + `src/api/db-exempt.ts` — the
  runtime boot gates the §5 SQL mirrors; `scripts/validate-force-rls.mjs` — the
  full validation harness.
