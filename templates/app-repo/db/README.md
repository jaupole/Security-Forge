# `db/` starter — new ecosystem app (DB-unification D14)

Drop-in starting point for a new app that joins the SecForge ecosystem data plane. It encodes the
decisions the five existing apps converged on, so a new app is conformant on day one instead of
being retrofitted later.

**Read first:** the authoritative specs live in the `db-unification` bundle —
`specs/data-standards.md` (the fleet rules + conformance harness), `specs/core-schema.md` (the
canonical-core DDL/APIs), and ADRs [0029](../../../docs/02-decisions/0029-per-app-database-strategy.md)
(per-app DBs), [0041](../../../docs/02-decisions/0041-canonical-core-data-spine.md) (the spine),
[0042](../../../docs/02-decisions/0042-rls-guc-standard-app-org-id.md) (the `app.org_id` GUC),
[0043](../../../docs/02-decisions/0043-ecosystem-db-shared-package.md) (`@jaupole/ecosystem-db`),
[0044](../../../docs/02-decisions/0044-physical-db-consolidation.md) (the consolidated cluster).

## Files

| File | What it is |
|---|---|
| `rls-template.sql` | The RLS shape EVERY org-scoped table must have (`data-standards.md §3`). `app.org_id` GUC, FORCE RLS. |
| `core-projections.sql` | Read-only local projections of Control's canonical entities (`core_people`/`core_clients`/`core_engagements`) + the sync cursor. |
| `core-sync.stub.ts` | The poller that keeps those projections fresh (pull from Control's `core-export`, per-entity cursor, version-guarded upsert, 24h reconcile). A skeleton — PM's `src/lib/core-sync.ts` is the reference implementation to copy. |
| `conformance-manifest.json` | The `db/conformance-manifest.json` the harness checks the live schema against. Fill in your tables. |
| `harness-ci.snippet.yml` | The CI step that runs the conformance harness against your migration-built test DB. Paste into your image-build workflow. |

## Wiring checklist for a new app

1. **Migrations**: adopt `@jaupole/ecosystem-db`'s `/migrate` runner (ADR-0043) — a ~15-line
   `src/db/migrate.ts` wrapper. Pass no `roleStrategy` unless you use `SET ROLE` / a FORCE-RLS
   cutover migration (only Control does).
2. **Roles**: one app login role (`<app>`), NOBYPASSRLS. Add a NOLOGIN `<app>_app` SET-ROLE split
   ONLY if you use `SECURITY DEFINER` functions (MH/PM do; PF/BM do not).
3. **RLS**: every org-scoped table gets the `rls-template.sql` shape. Set `app.org_id` per request
   via `SET LOCAL` in your tx helper.
4. **Projections**: apply `core-projections.sql`; wire `core-sync.stub.ts`; register your app as a
   `core-export` consumer with Control (system token).
5. **Manifest + CI**: fill `conformance-manifest.json`, add `harness-ci.snippet.yml` to your build.
6. **Cluster**: your database is added to `ecosystem-db` (ADR-0044) — see
   `docs/03-runbooks/ecosystem-db-operations.md` §"Add a database for a new app" and
   `docs/03-runbooks/new-app-bootstrap.md` §Data.
