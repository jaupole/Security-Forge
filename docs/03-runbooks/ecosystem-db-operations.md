# ecosystem-db operations (DB-unification P5)

The consolidated Postgres cluster: ONE CNPG cluster (`ecosystem-db/ecosystem-db`)
hosting FIVE app databases (`control`, `member_hub`, `proposal_forge`,
`business_manager`, `project_manager`). Keycloak + SpiceDB keep their own clusters.

Manifests: `platform/manifests/ecosystem-db/`. All applies go through
`apply-manifest.sh` over `ssh secforge` (envsubst) — **never raw kubectl** (ships
literal `${STORAGE_CLASS}`).

> ## ⚠️ TWO HUMAN GATES — do not automate past these
> - **GATE A — OpenBao break-glass day.** The root token is dead; only the operator
>   has break-glass access. Everything OpenBao-touching is batched for that day:
>   `05c`/`05j` (the `ecosystem-db-vso` role), `04-vso-bindings`, the 5 per-app
>   `DATABASE_URL` host rotations, and `openbao-root-token-tmp` deletion at EOD.
> - **GATE B — per-app go/no-go.** Each cutover scales a live public app to 0.
>   Get explicit operator sign-off per app. The **restore-drill precondition**
>   (below) also lives under this gate — run it and show the result first.

---

## Phase 0 — Pre-bao-day prep (additive, inert; apply any time before the bao day)

The empty cluster + its netpols/backup wiring are inert until an app's
`DATABASE_URL` is repointed, so they can land ahead of the cutover day.

```bash
ssh secforge   # then, as ops (git) + sudo -n (kubectl) per CLAUDE.md
# From the ops clone, after `git pull`:
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/01-namespace.yaml
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/03-serviceaccount.yaml
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/02-cnpg-cluster.yaml
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/05-network-policies.yaml
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/06-objectstore.yaml
platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/07-cnpg-scheduled-backup.yaml
# MinIO cross-ns netpol (ecosystem-db added to both allow-lists):
platform/lib/apply-manifest.sh platform/manifests/minio/03-allow-cross-ns-clients.yaml
```

Verify the cluster reaches Ready (backups will FAIL until GATE A renders
`cnpg-minio-credentials` — that's expected pre-bao-day):

```bash
sudo -n kubectl get cluster -n ecosystem-db ecosystem-db          # → Cluster in healthy state
sudo -n kubectl get pods   -n ecosystem-db                        # ecosystem-db-1 2/2 Running
```

## Phase 1 — Restore-drill precondition (GATE B; run BEFORE any cutover)

The spec requires a recent successful restore drill. Use the `verify-restore` ns
pattern (already allow-listed in the MinIO cross-ns netpol; see
`project_r4_force_rls` notes / control-db-restore.md). Restore the LATEST base
backup of an existing app cluster into `verify-restore`, confirm it reaches Ready
and a table row count matches, then tear it down. **Show the operator the result.**

> **✓ RUN 2026-07-08 — PASSED.** `09i-control-restore-drill.sh` restored
> `control-db-daily-20260708024500` into `verify-restore` (healthy in 120s); the
> FORCE-RLS posture gate passed every assertion (36 FORCE'd control_owner RLS
> tables, 35 org_isolation + 13 exempt_read policies, `control` non-bypassrls sees
> 0 sentinel rows, `control_reader` cross-org read), then auto-torn-down. Backups
> restore + the FORCE-RLS posture survives (rule 41). This satisfies the P5 precond.
>
> **Barman-plugin note (flagged at the drill):** CNPG warns that
> `externalClusters.barmanObjectStore` (the recovery syntax in the app clusters
> and 09i) is deprecated and removed in CNPG 1.30. The ecosystem-db **backups**
> already use the new barman-cloud **plugin** (06-objectstore.yaml + the cluster's
> `plugins:` block), but a full-DR **recovery** of ecosystem-db would still use the
> deprecated `externalClusters.barmanObjectStore` block. Migrate the recovery path
> to the plugin's recovery mechanism before CNPG 1.30 (fleet-wide item, not a P5
> blocker — the cutover DATA move below is logical pg_dump/pg_restore, unaffected).

## Phase 2 — GATE A: the OpenBao break-glass day

Order matters. Do ALL of this on the one break-glass day:

1. **VSO role + backup creds** (so the cluster can archive WAL):
   ```bash
   platform/components/05c-openbao-configure.sh   # only if a NEW policy name was added; this PR reuses `vso`
   platform/components/05j-app-vso-roles.sh        # upserts the ecosystem-db-vso role
   platform/lib/apply-manifest.sh platform/manifests/ecosystem-db/04-vso-bindings.yaml
   # Verify the secret rendered, then confirm the FIRST real WAL object lands in MinIO
   # (netpol/creds are silent-failure-prone — check the object, not policy presence):
   sudo -n kubectl get secret -n ecosystem-db cnpg-minio-credentials
   sudo -n kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- \
     psql -U postgres -c "SELECT pg_switch_wal();"      # force a WAL; then check MinIO backups/cnpg/ecosystem-db/
   ```
2. **Role bootstrap — apply the 5 filtered role dumps UP FRONT** (reproduces exact
   posture + SCRAM password hashes, so only the URI host changes). Per app:
   ```bash
   # Dump roles from the LIVE app cluster, drop the CNPG-managed roles, apply to ecosystem-db.
   ssh secforge 'sudo -n kubectl exec -n member-hub member-hub-db-1 -c postgres -- \
     pg_dumpall -U postgres --roles-only' \
     | grep -vE "CREATE ROLE (postgres|streaming_replica|cnpg_metrics_exporter)|ALTER ROLE (postgres|streaming_replica|cnpg_metrics_exporter)|^--|^$" \
     | ssh secforge 'sudo -n kubectl exec -i -n ecosystem-db ecosystem-db-1 -c postgres -- psql -U postgres -v ON_ERROR_STOP=1'
   ```
   Repeat for control / proposal-forge / business-manager / project-manager.
   **Re-verify posture against the live matrix** (reproduce EXACTLY):
   | db | roles | notes |
   |---|---|---|
   | control | `control`, `control_migrator`, `control_owner`(NOLOGIN), `control_reader` | all NOBYPASSRLS |
   | member_hub | `member_hub`(BYPASSRLS), `member_hub_app`(NOLOGIN), `audit_verifier` | owner BYPASSRLS REQUIRED (SECURITY DEFINER) — keep it |
   | proposal_forge | `proposal_forge` | single, NOBYPASSRLS |
   | business_manager | `business_manager` | single, NOBYPASSRLS |
   | project_manager | `project_manager`(BYPASSRLS), `project_manager_app`(NOLOGIN) | |
   ```bash
   # Confirm on ecosystem-db:
   sudo -n kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- psql -U postgres -c \
     "SELECT rolname, rolcanlogin, rolbypassrls, rolsuper FROM pg_roles WHERE rolname NOT LIKE 'pg_%' ORDER BY 1;"
   ```
3. **Then run the 5 cutovers** (Phase 3), one app at a time — Control LAST.

## Phase 3 — Cutover, per app (GATE B each; order: member_hub → project_manager → proposal_forge → business_manager → control)

For `<app>` / `<ns>` / `<db>` / `<owner>` (e.g. member-hub / member-hub / member_hub / member_hub):

1. **Announce + scale to 0** (single-operator platform, low ceremony):
   ```bash
   sudo -n kubectl scale deploy -n <ns> <app> --replicas=0
   ```
2. **Create the database + restore the data** (roles already exist from Phase 2.2):
   ```bash
   sudo -n kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- \
     psql -U postgres -c "CREATE DATABASE <db> OWNER <owner> ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"
   ssh secforge 'sudo -n kubectl exec -n <ns> <ns>-db-1 -c postgres -- pg_dump -Fc -U postgres <db>' \
     | ssh secforge 'sudo -n kubectl exec -i -n ecosystem-db ecosystem-db-1 -c postgres -- pg_restore -U postgres -d <db> --no-privileges=false --exit-on-error'
   ```
   (`-Fc` custom format; grants/ownership ride along because the roles pre-exist.)
3. **Apply the app-SIDE egress netpol** (additive; permits <ns> → ecosystem-db).
   Save as `platform/manifests/<app>/05x-allow-egress-to-ecosystem-db.yaml` and apply:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-egress-to-ecosystem-db
     namespace: <ns>
     labels: { secforge.platform/component: <app>, secforge.platform/policy-tier: layer-a }
   spec:
     podSelector: {}          # app pods + migration Job both need it
     policyTypes: [Egress]
     egress:
       - to:
           - namespaceSelector:
               matchLabels: { kubernetes.io/metadata.name: ecosystem-db }
         ports:
           - { protocol: TCP, port: 5432 }
           - { protocol: TCP, port: 15008 }   # HBONE — ambient mesh
   ```
   > **First app only (member_hub): VALIDATE the ambient/HBONE path end-to-end**
   > before doing the other four (per the P5 addendum). If 5432-only suffices,
   > trim 15008; if neither connects, check whether the ecosystem-db ns ambient
   > label enrolled the db pod (`istioctl ztunnel-config`).
4. **GATE A — rotate `DATABASE_URL` host in OpenBao** (operator, break-glass):
   set the `DATABASE_URL` key inside `secret/apps/<app>/runtime` to host
   `ecosystem-db-rw.ecosystem-db.svc.cluster.local` (keep user/password/db —
   password is unchanged because the roles carry their original SCRAM hash). Then
   force VSO to re-render (delete the rendered secret or bump `refreshAfter`):
   ```bash
   sudo -n kubectl delete secret -n <ns> <app>-app-secrets    # VSO re-renders from the new KV value
   ```
5. **Scale up + verify:**
   ```bash
   sudo -n kubectl scale deploy -n <ns> <app> --replicas=1
   sudo -n kubectl get pods -n <ns>                                  # app 1/1 (2/2 MH/control), migrate Job Complete
   # /healthz + one authenticated write (browser or an authed curl over the tailnet).
   # RLS spot-check MUST use the ENFORCED role (SET ROLE), not the BYPASSRLS owner:
   sudo -n kubectl exec -n ecosystem-db ecosystem-db-1 -c postgres -- psql -U postgres -d <db> -c \
     "SET ROLE <runtime_role>; SET app.org_id='<orgA>'; SELECT count(*) FROM <a_tenant_table>;"   # then orgB → 0 cross-org rows
   # Row-count completeness diff old-vs-new:
   # pg_stat_user_tables n_live_tup per table, old <ns>-db-1 vs ecosystem-db.
   # Conformance harness against the NEW db, with the REAL runtime_role (see §D fix):
   #   control=control, member_hub=member_hub_app, proposal_forge=proposal_forge,
   #   business_manager=business_manager, project_manager=project_manager_app
   ```
6. **Keep the OLD cluster STOPPED but present for 7 days** (hibernation
   annotation `cnpg.io/hibernation: "on"`). Rollback in this window = repoint
   `DATABASE_URL` back + scale up.

## Phase 4 — Decommission (after 7 clean days per app)

Delete the old `<app>` Cluster + PVCs + its ScheduledBackup + ObjectStore; keep
the final MinIO backup 90 days. Keep each `platform/manifests/<app>/02-cnpg-cluster.yaml`
in the repo **marked retired** (multi-box escape hatch). Free the app namespaces'
db-pod resource requests in their ResourceQuotas.

## Ongoing operations

- **Backups:** daily ScheduledBackup `ecosystem-db-daily` (03:15 UTC) → MinIO
  `s3://backups/cnpg/ecosystem-db`, 30-day retention, continuous WAL archiving.
- **Restore drill:** quarterly — restore the latest base backup into `verify-restore`
  (allow-listed in the MinIO netpol), confirm Ready + a row count, tear down.
- **Add a database for a new app:** `CREATE DATABASE <db> OWNER <role>`, create the
  app's role(s) with the standard posture (single NOBYPASSRLS login role; add a
  SET-ROLE `_app` split only if the app uses SECURITY DEFINER functions), add the
  app ns to `allow-ingress-from-apps` (05-network-policies.yaml) + the app-side
  egress netpol, and point its `DATABASE_URL` at `ecosystem-db-rw`.
- **Split a database out to its own cluster/box (multi-box escape hatch):**
  `pg_dump -Fc` the database + its filtered role dump → restore into a fresh
  per-app CNPG cluster (un-retire `platform/manifests/<app>/02-cnpg-cluster.yaml`)
  → rotate that app's `DATABASE_URL` host in OpenBao → scale up → verify → remove
  the app from `allow-ingress-from-apps`. No cross-DB coupling exists, so this is
  always a clean dump/restore + connection-string change.

## Rollback

Old clusters are untouched until Phase 4. Rollback = repoint `DATABASE_URL` back
to `<app>-db-rw.<ns>.svc` + scale up. After the Phase-4 deletes, rollback = restore
from MinIO into a fresh per-app cluster (the retired manifests are still in git).
