# Project Tracker — SecForge integration

First app cutover target for Phase 10. Source repo lives at
`C:/Users/jaupo/Projects/Project Tracker/` and is independent (separate
git repo, separate Prisma schema as source of truth, separate runtime).

This directory holds the SecForge platform's view of PT — the schema
migration, RLS policies, data import scripts, and (later) the cluster
deployment manifests.

## Files

| File | Purpose |
|---|---|
| [`TENANT.md`](./TENANT.md) | The pinned AECOM-BD-Jason tenant UUID. Reused across Postgres / Keycloak / SpiceDB. NEVER regenerate. |
| [`migrations/000-create-role.sql`](./migrations/000-create-role.sql) | `project_tracker_app` base role + schema USAGE/CREATE grants. |
| [`migrations/001-prisma-baseline.sql`](./migrations/001-prisma-baseline.sql) | **Verbatim copy** of the PT-repo Prisma migration `20260505234638_10_1_3_secforge_integration`. 14 tables under `project_tracker.*` with `tenant_id UUID NOT NULL`. Do not hand-edit. |
| [`migrations/002-rls-policies.sql`](./migrations/002-rls-policies.sql) | Per-table `tenant_isolation` policies. Each policy filters by `app.tenant_id` GUC; fail-closed when GUC unset. |
| [`migrations/apply.sh`](./migrations/apply.sh) | Operator-run idempotent applier for 000 / 001 / 002 + DML-grant + default-privileges step. Uses postgres superuser via peer auth. |
| [`migrations/003-import.sh`](./migrations/003-import.sh) | One-shot: `pg_dump` from local docker-compose Postgres → sed-transform-with-tenant-id → import to cluster as the OpenBao-minted `project-tracker-migrate` role. |
| [`migrations/004-verify.sh`](./migrations/004-verify.sh) | Row-count parity check + RLS scoping assertions. Run as the runtime `project-tracker-readwrite` role to match production semantics. |

## Cross-references

- Audit doc: [`docs/01-architecture/apps/project-tracker.md`](../../docs/01-architecture/apps/project-tracker.md)
- OpenBao policy: [`infrastructure/openbao/policies/project-tracker.hcl`](../../infrastructure/openbao/policies/project-tracker.hcl)
- OpenBao + Postgres provisioning script: [`infrastructure/project-tracker/provision-db-and-bao.sh`](../../infrastructure/project-tracker/provision-db-and-bao.sh)
- SpiceDB schema additions (10.1.2): [`infrastructure/spicedb/schema.zed`](../../infrastructure/spicedb/schema.zed) (the `project_tracker/*` definitions block)

## Convention — promoting Prisma migrations to the platform repo

The PT repo is the source of truth for the database schema. When PT's
schema changes:

1. PT operator runs `prisma migrate dev --name <change>` against the
   local docker-compose Postgres and commits the new migration in
   the PT repo.
2. The new `migration.sql` is promoted into this directory as
   `00N-<change>.sql` (next sequential number — 002 is reserved for
   the RLS policies; promotions start at 003 and skip RLS-related
   slots).

   *Wait — slot 003 is `import.sh` (a script, not a migration), and
   004 is `verify.sh`. The numbering is split across file-types.
   Subsequent migrations should pick the next free integer (005+) to
   avoid colliding with the script slots.*
3. If the new migration adds new tables, extend
   `002-rls-policies.sql` with matching `tenant_isolation` policy
   blocks (one per new table). If it modifies existing tables (column
   adds, index changes), no RLS edit needed.
4. Re-run `apply.sh` against the cluster. apply.sh is idempotent on
   the role-grant + RLS-policy steps, but NOT on the Prisma-generated
   table creates — re-applying a migration that was already applied
   will error (Prisma omits `IF NOT EXISTS` from `CREATE TABLE`). The
   normal path is: drop the schema, re-run apply.sh from scratch.
   Save data first if you don't want to re-import.

## Quick reference — running the cutover

```bash
# Pre-req: PF docker-compose db running with PT data
cd 'C:\Users\jaupo\Projects\Proposal Forge' && docker compose up -d db
docker exec proposalforge-db-1 psql -U proposalforge -c "CREATE DATABASE project_tracker;" 2>/dev/null || true

cd 'C:\Users\jaupo\Projects\Project Tracker'
DATABASE_URL='postgres://proposalforge:proposalforge@localhost:5432/project_tracker' npx prisma migrate deploy
DATABASE_URL='postgres://proposalforge:proposalforge@localhost:5432/project_tracker' npx prisma db seed

# OIDC login + provision
export BAO_ADDR=https://bao.secforge.local BAO_SKIP_VERIFY=1
~/.local/bin/bao login -method=oidc role=admin -format=json | jq -r .auth.client_token > ~/.bao-token
export BAO_TOKEN=$(cat ~/.bao-token)

cd 'C:\Users\jaupo\Projects\Security Forge'
bash infrastructure/project-tracker/provision-db-and-bao.sh

# Apply schema + RLS to cluster
bash apps/project-tracker/migrations/apply.sh

# Import data + verify
export TENANT_UUID=833cc9ee-81b6-4e79-a4d7-e104fa37aa12
bash apps/project-tracker/migrations/003-import.sh
bash apps/project-tracker/migrations/004-verify.sh
```

`004-verify.sh` exits 0 on success with a parity table + the three RLS
assertions printed.

## Status

- 10.1.1 audit ✅ (2026-05-04)
- 10.1.2 SpiceDB schema additions ✅ (2026-05-05)
- **10.1.3 Postgres schema migration ✅ (2026-05-05)** — this commit
- 10.1.4 BFF-injected identity wiring — pending
- 10.1.5 SAM_GOV_API_KEY through OpenBao — pending
- 10.1.6 Build the BFF — pending
- 10.1.7 Build container images — pending
- 10.1.8 Deploy — pending
- 10.1.9 Frontend pickups — pending
- 10.1.10 Verification + sign-off — pending
