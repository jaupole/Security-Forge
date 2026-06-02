# Runbook — FORCE ROW LEVEL SECURITY cutover (control plane)

> Audit ref: **EC-003 / SC-3.4 / R4**. Turns the control-plane Postgres from
> "RLS enabled, owner bypasses" into "RLS enabled **and FORCED**, runtime role
> cannot bypass tenant isolation". Last validated: **2026-06-01** (PG 17.5 copy,
> prod-accurate role model, 23/23 checks green).

This is the procedure `src/api/db-exempt.ts` points at when `PGREADER_*` is
unset. Read it end-to-end before the window. It coordinates two repos:

- **ecosystem-control** — migrations `060`/`061`, the app rewires
  (`withTx`/`withExemptRead`), and the startup posture gate
  (`assertForceRlsPosture`). Branch `sec/force-rls-cutover`.
- **Security-Forge** — CNPG `managed.roles`, VSO bindings, the migration Job,
  and the backend Deployment env. Branch `sec/control-db-rls-roles` (PR #49).

Both must ship in the **same window**: the new app image refuses to start
until `060` has FORCEd RLS (the gate is fail-closed), and the old app image
returns 0 rows on cross-org reads once `060` lands.

---

## 1. Role model (after cutover)

| Role | Login | Owns tables | BYPASSRLS | Purpose |
|------|-------|-------------|-----------|---------|
| `control` | yes | the non-RLS **operational** tables (idempotency_keys, billing_*, platform_*, ecosystem_*, org_app_*, organizations, apps, …) | no | Runtime app role. DML on those + on the 21 RLS tables (via grant); bound by RLS for real. |
| `control_owner` | **no** | the 21 RLS tables + `audit_log` + `schema_migrations` + ticket_number_seq + 4 audit functions + 3 enums | no | Owns only the **security-critical** objects. Never connected at runtime — that is what makes `FORCE` meaningful (FORCE binds even the owner) and what stops the runtime role from DISABLE-ing RLS or DROPping the audit triggers. |
| `control_migrator` | yes | none | no | The migration Job connects as this. Member of `control` + `control_owner`; `migrate.ts` does `SET ROLE control_owner` so `061+` objects are owner-correct. |
| `control_reader` | yes | none | no | Backs `withExemptRead`. `SELECT`-only on the 9 exempt tables (+ a permissive `exempt_read` policy) and on `organizations`/`apps`. Cannot write. |

**Ownership only moves for objects whose owner-DDL is a tenant-isolation or
audit-integrity risk** — the 21 RLS tables, `audit_log`, and their deps. The
non-RLS operational tables STAY owned by `control` (it needs ongoing direct
access; moving them — an over-broad `REASSIGN OWNED` — is precisely what an
early draft did, stripping `control`'s access to idempotency / billing /
platform and breaking every mutating request).

The 9 **exempt** tables (cross-org/public reads): `organization_memberships`,
`organization_apps`, `org_roles`, `pending_invitations`, `tickets`,
`ticket_notes`, `org_graphics`, `org_brand_fonts`, `organization_public_config`.
All other RLS tables are `withTx`-only.

---

## 2. Pre-cutover checklist

- [ ] OpenBao holds `secret/data/apps/control/db-migrator` and `.../db-reader`
      (username/password). Covered by the existing `control.hcl`
      `secret/data/apps/control/+` grant — no policy change.
- [ ] Security-Forge PR #49 ready: CNPG `managed.roles` (control_owner /
      control_migrator / control_reader), the two VSO `VaultStaticSecret`
      bindings (`control-db-migrator`, `control-db-reader`), the migration Job,
      and `09-backend-deployment.yaml` injecting `PGREADER_USER` /
      `PGREADER_PASSWORD` from `control-db-reader` (with `optional: true`).
- [ ] ecosystem-control PR merged to the image you will deploy: migrations
      `060`/`061`, the `withTx`/`withExemptRead` rewires, `db-assert.ts`.
- [ ] **DB-copy validation green** on a *restored copy* — see §3. Do NOT skip.
- [ ] Maintenance window scheduled; status page updated. Expect a brief
      cross-org-read blip between the `060` apply and the new-image rollout.

---

## 3. DB-copy validation (gate — rule 106, NEVER prod)

Validate against a **restored copy**, never the live cluster. Two layers:

### 3a. Logic + posture (repeatable, no cluster)

`ecosystem-control` ships an ephemeral-Postgres harness (PGlite 17.5 ≈ prod's
CNPG 17.6, real pgcrypto) that applies `001..061` under the **prod-accurate
role model** (001-059 as `control`, 060 as superuser, 061 as `control_owner`,
with the `056` email-config drift simulated) and asserts the full posture,
runtime enforcement, the runtime role's access to NON-RLS operational tables,
the audit hash-chain, tamper resistance, and the rollback round-trip — **40
checks**. Appendix A is the script. Across two audit rounds it found and gated
**four cutover blockers** (all now fixed):

1. **CRITICAL** — the over-broad `REASSIGN OWNED BY control` moved every
   control-owned object (incl. idempotency_keys, billing_*, platform_*,
   ecosystem_*, org_app_*) to the NOLOGIN `control_owner`, leaving `control`
   "permission denied" on every idempotency / billing / platform path. Fix:
   drop the blanket REASSIGN; `control` keeps the non-RLS tables, only the
   security-critical objects move (explicit `ALTER OWNER`).
2. `REASSIGN OWNED BY postgres` aborts on pinned system catalogs (removed).
3. `GRANT ... ON organizations, apps TO control_reader` cannot run as
   `control_owner` (not the owner) — moved to `060` (superuser).
4. `INSERT INTO schema_migrations` from `061`/`062+` needs `control_owner` to
   own `schema_migrations` — `060` re-homes it explicitly; the down restores it.

> Two lessons baked into the harness: (a) an all-as-superuser test passes and
> ships the break — it MUST apply `061` as `control_owner`; (b) a forward-only
> test misses the rollback + the non-RLS-table access — it must probe both.

```
cd ecosystem-control
pnpm add -w -D @electric-sql/pglite     # ephemeral test dep; do not commit
node scripts/validate-force-rls.mjs     # Appendix A — expect "N passed, 0 failed"
pnpm remove @electric-sql/pglite
```

### 3b. Real-data fidelity (scratch CNPG, in-cluster)

Confirms the cutover works against **production's actual ownership + rows**
(genuine `NULL` GUC path, real drift, real row volumes) without touching prod:

1. Provision a **scratch** CNPG cluster in a throwaway namespace (e.g.
   `control-validate`) via `bootstrap.recovery` from the latest
   `control-db` Barman backup. It shares no Service/ingress with prod.
2. Apply `060` as the scratch superuser by hand, then run the migration Job
   image's `db:migrate` (applies `061` as `control_migrator`→`control_owner`).
3. Translate Appendix A's assertions to `psql` against the scratch primary
   (same SQL; connect as `control`, `control_owner`, `control_reader` in turn).
   All must pass — especially: `control` sees 0 cross-org rows; `control_owner`
   sees 0 with no context (FORCE); `control_reader` reads exempt tables + JOINs
   `organizations`; `061` applied cleanly as `control_owner`.
4. **Tear the scratch namespace down.** It held a full PII copy.

Proceed to §4 only when both layers are green.

---

## 4. Cutover window

Ordering is constrained: `060` must land **before** the new image starts
(`assertForceRlsPosture` is fail-closed), and the old image degrades once
`060` lands. Keep steps 2-4 tight.

1. **Apply Security-Forge #49** (roles, VSO secrets, Job, deployment env).
   Confirm `control_owner`/`control_migrator`/`control_reader` exist on the
   live `control-db` cluster and the `control-db-migrator`/`control-db-reader`
   K8s Secrets are synced by VSO.
2. **Apply `060` by hand as the in-pod superuser.** `060` needs superuser
   (ALTER ROLE / REASSIGN OWNED / ALTER OWNER / FORCE); `enableSuperuserAccess`
   is `false`, so use a local-socket psql in the primary pod:
   ```
   kubectl exec -n control -c postgres control-db-1 -- \
     psql -U postgres -d control_db -v ON_ERROR_STOP=1 -f - < migrations/060_force_rls_and_ownership.sql
   ```
   (Copy the file in first, or pipe as shown.) `ON_ERROR_STOP=1` aborts on the
   first error — if it does, STOP and go to §6.
3. **Run the migration Job** (`control-db-migrate`) — it connects as
   `control_migrator` and applies `061` (as `control_owner`). Verify it
   completes; confirm `schema_migrations` has `060` and `061`.
4. **Roll the new backend image** (the deployment from #49, with `PGREADER_*`
   wired). On boot it runs `assertForceRlsPosture`:
   - PASS → it serves via `withTx`/`withExemptRead`.
   - FAIL (`process.exit(1)`, CrashLoop) → posture is wrong; go to §6.

---

## 5. Verification

- [ ] New pods `Ready`; logs show no `FORCE-RLS assert` error.
- [ ] `relforcerowsecurity = true` on all 21 tables (psql as superuser).
- [ ] Smoke: a public read works (`GET /api/v1/public/orgs/by-slug/:slug`),
      an org-scoped read works (org dashboard), the `/me` org-switcher lists
      memberships across orgs, the admin ticket inbox loads (cross-org exempt
      read), and `GET /api/v1/orgs` shows the **true** member counts.
- [ ] `control` posture: `SELECT rolsuper, rolbypassrls FROM pg_roles WHERE
      rolname='control'` → both `false`; owns none of the 21 tables.

---

## 6. Rollback

If `060` aborts, the new image won't start, or §5 smoke fails:

1. Roll the backend Deployment back to the previous image (old code path).
2. Apply the down migrations as the in-pod superuser, newest first:
   `061_exempt_read_policies.down.sql` then
   `060_force_rls_and_ownership.down.sql` — these remove `FORCE`, restore
   `control` as owner, and drop the exempt role/policies, so the old image
   works again.
3. Leave #49's roles in place (harmless) or revert it; re-validate per §3
   before re-attempting.

Because `060`/`061` are wrapped per-file in `BEGIN/COMMIT`, a mid-migration
failure leaves that file's changes rolled back — but a *partial sequence*
(060 applied, 061 not) needs the matching down files, in order.

---

## 7. Post-cutover

- The runtime role `control` is now bound by RLS. Every code path that reads a
  tenant table does so through `withTx({ userId, orgId })` (org-scoped) or
  `withExemptRead` (cross-org/public, control_reader).
- **Maintenance key scripts** (`rotate-org-transit-key.ts`,
  `rewrap-org-vendor-keys.ts`) run per-org under `withTx({ orgId })` as the
  normal `control` role — deliberately NOT a BYPASSRLS/superuser Job, so the
  "no role bypasses tenant isolation, even maintenance" invariant holds. See
  also [transit-key-rotation.md](./transit-key-rotation.md).
- If a future migration adds an RLS table: add it to `060`'s FORCE list AND to
  `db-assert.ts`'s `FORCE_RLS_TABLES`; decide exempt-vs-withTx and, if exempt,
  add the `061` grant + `exempt_read` policy; re-run §3.
- **Migration 062+ coordination** (see the guide in `src/db/migrate.ts`): files
  run as `control_owner`, which owns ONLY the security-critical set. A migration
  that must write or own a control-owned object (a non-RLS operational table, or
  a GRANT on one) cannot do it as `control_owner` — fold that into a
  superuser-applied step (the `060` pattern), not the `control_owner` loop. The
  planned Control migration 062 (website-designer work) must follow this.

---

## Appendix A — validation harness

`ecosystem-control/scripts/validate-force-rls.mjs` (run per §3a, 40 checks).
Applies all migrations under the prod-accurate role model and asserts:

- **Posture**: 21 tables ENABLE + FORCE; `control` non-super/non-bypass/non-owner; `control_owner` owns all 21.
- **Enforcement**: `control` (and `control_owner`) see 0 rows with no org context (FORCE binds the owner); org-scoped `withTx` sees only its org; the `organization_memberships` `user_id` branch self-reads cross-org; `control_reader` reads all exempt rows + JOINs `organizations`/`apps`, is denied on non-exempt tables + denied writes; the `/api/v1/orgs` `member_count` subquery returns the true count; `control` DML is org-scoped (rotate/rewrap path).
- **Non-RLS access** (REASSIGN regression guard): `control` can SELECT all 14 non-RLS operational tables (idempotency/billing/platform); only `schema_migrations` is control_owner-owned.
- **Audit integrity**: `control`'s `audit_log` INSERTs seal (prev_hash/row_hash) and `verify_audit_log_chain()` reports no break.
- **Tamper resistance**: `control` cannot DISABLE RLS / DROP POLICY / disable the audit seal trigger / UPDATE audit_log.
- **Rollback round-trip**: `061.down` + `060.down` apply, FORCE comes off, `control` re-owns the 21 + `audit_log` + `schema_migrations`, exempt policies drop, the 060/061 rows are deleted, and `control` can write `schema_migrations` again.

PGlite-only accommodations (NOT prod behaviour): `CREATE EXTENSION pgcrypto`
is stripped (`gen_random_uuid()` is built-in in PG13+); "no context" uses an
all-zeros UUID sentinel because a rolled-back custom GUC leaks as `''` in
PGlite (real PG → `NULL`; the sentinel matches no real row, so it is
assertion-equivalent). The genuine-`NULL` path is exercised by §3b on real PG.
