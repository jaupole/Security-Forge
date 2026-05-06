# Project Tracker — SecForge Integration Audit

> **Phase 10.1 — audit output.** Maps the existing Project Tracker codebase onto the SecForge platform as the first cutover target. Lives at `C:\Users\jaupo\Projects\Project Tracker\`.
>
> Last updated: 2026-05-04 (audit)
>
> **Companion docs:** [phase-10 prompt](../../05-claude-code-prompts/phase-10-integrate-proposal-forge-project-tracker.md) · [04-bff-pattern.md](../04-bff-pattern.md) · [06-api-pattern.md](../06-api-pattern.md) · [10-helloworld-demo.md](../10-helloworld-demo.md)

---

## Why this app first

Project Tracker is the **easiest possible first integration**, by a wide margin. Three properties make it so:

1. **No existing auth code to strip.** The Phase 10 prompt's "Strip local auth, accept BFF-injected identity" step is largely a no-op here. There is no passport.js, no jsonwebtoken, no express-session, no bcrypt, no login page, no register page, no auth middleware. The CLAUDE.md at `C:\Users\jaupo\Projects\Project Tracker\CLAUDE.md` § "Deferred / parked work" is explicit: "Project Tracker is currently single-user (Jason). When we add auth it should mirror Proposal Forge's scheme..." Auth was deferred precisely so that Project Tracker could pick up whatever scheme the platform settled on. **Phase 10 IS that scheme.**
2. **Single outbound secret.** Just `SAM_GOV_API_KEY` for the SAM.gov opportunity poller (Week 4). No Anthropic / OpenAI / Google AI keys (CLAUDE.md hard rule: no API-credit AI in the backend; AI runs via the MCP server on Jason's Claude subscription). Compare to Proposal Forge's expected Anthropic + Google + OpenAI + GSA fan-out.
3. **Single user, single domain.** No multi-tenancy refactor. Tenant boundary is "Jason's BD effort within AECOM Digital Infrastructure." Phase 10 introduces `tenant_id` and RLS, but the values stay constant across every row in every table.

Doing Project Tracker first proves the integration pattern with the smallest possible blast radius. Proposal Forge inherits the now-tested playbook.

---

## Domain model (carried over from PT's `prisma/schema.prisma`)

The schema is mature — Weeks 1–4 are fully built; Week 5 (MCP server) is in flight. Models, with their primary purpose:

| Model | Purpose | Notes |
|---|---|---|
| `Person` | Team roster — Jason's 10+ colleagues at AECOM. **Not an auth subject.** | `roleOnTeam`, `billRateCents`, `costRateCents` are HR/billing fields, not RBAC roles |
| `Project` | Active engagements. PM-owned, budget-tracked | `pmId → Person.id`; multiple `ProjectBudgetLine` rows per |
| `ProjectBudgetLine` | Per-role budget detail under a Project | Cascade-deleted with parent |
| `Task` | Polymorphic — tied to `parentType ∈ {project, pursuit, proposal}` + `parentId` | Owned by a Person; can link to a `CommsLog` entry |
| `Pursuit` | Pre-award business-development opportunities | Stages: identified → qualified → capture → proposal → submitted → won/lost/no_bid/withdrawn |
| `CommsLog` | Internal correspondence log (project / pursuit / bl_request) | Action-required flag drives task auto-creation |
| `OppWatchTrack` / `Query` / `Result` | SAM.gov opportunity watcher | Cron-driven via `node-cron` in the server; query criteria stored as JSON |
| `BlRequest` | "Borrowed & Lent" — pricing requests that flow through Jason | Includes `BlRequestContact` (people involved) + `BlSubmission` (revisions) + `BlSubmissionLine` (per-role lines) |
| `AuditLog` | Append-only change log on key entities | `changedById` is currently always `null`; Phase 10 populates from Keycloak `sub` |

The schema has clean shape — every multi-tenant table will need a `tenant_id` column added (Phase 10.{N}.3 step 4).

The full-fidelity model lives in [`Project Tracker/prisma/schema.prisma`](file:///C:/Users/jaupo/Projects/Project%20Tracker/prisma/schema.prisma). Don't duplicate it here — point at it.

---

## Permissions model — SpiceDB translation

PT today has effectively no permission model: every endpoint is wide open because there's a single user. The SpiceDB schema we add must support the **future** state (multi-user team coordination on shared projects) while keeping the current single-user state trivially correct.

### Proposed schema additions to `infrastructure/spicedb/schema.zed`

```
// Existing definitions (organization, app, document) unchanged.

definition project_tracker/project {
    relation organization: organization
    relation owner: user           // the PM
    relation editor: user
    relation viewer: user

    permission view = viewer + editor + owner + organization->member
    permission edit = editor + owner + organization->admin
    permission delete = owner + organization->admin
    permission manage_budget = owner + organization->admin
}

definition project_tracker/pursuit {
    relation organization: organization
    relation owner: user
    relation editor: user
    relation viewer: user

    permission view = viewer + editor + owner + organization->member
    permission edit = editor + owner + organization->admin
    permission promote = owner + organization->admin   // pursuit → won → spawn project
}

definition project_tracker/task {
    relation parent_project: project_tracker/project
    relation parent_pursuit: project_tracker/pursuit
    relation owner: user
    relation assignee: user

    // A task inherits view/edit from whichever parent set the relation.
    permission view = owner + assignee + parent_project->view + parent_pursuit->view
    permission edit = owner + assignee + parent_project->edit + parent_pursuit->edit
    permission complete = owner + assignee + parent_project->edit + parent_pursuit->edit
}

definition project_tracker/bl_request {
    relation organization: organization
    relation primary_pm: user
    relation responsible: user

    permission view = primary_pm + responsible + organization->member
    permission edit = primary_pm + responsible + organization->admin
    permission submit = primary_pm + organization->admin
}

definition project_tracker/opp_watch_query {
    relation organization: organization

    permission view = organization->member
    permission edit = organization->admin   // only admins tune the SAM.gov queries
}
```

### Day-one tuples (single-user state)

```
project_tracker/project:*  organization: organization:aecom-bd-jason
project_tracker/project:*  owner:        user:jason@aecom.com
project_tracker/pursuit:*  organization: organization:aecom-bd-jason
project_tracker/pursuit:*  owner:        user:jason@aecom.com
...
organization:aecom-bd-jason  admin: user:jason@aecom.com
organization:aecom-bd-jason  member: user:jason@aecom.com
```

Jason is `admin` of his own organization, which gives him every permission on every entity by cascade. When colleagues land later, they get added as `viewer` / `editor` / `member` per project.

### Validator tests to add under `infrastructure/spicedb/tests/project-tracker/`

- `owner-can-edit-project` — `jason owner-of project:1` ⇒ `edit` on `project:1`
- `member-can-view-project` — `alice member-of org` + `project:1 organization-of org` ⇒ `view` on `project:1`
- `non-member-denied` — random user, no relation ⇒ no permissions
- `org-admin-cascades-to-edit` — `bob admin-of org` ⇒ `edit` on every project in the org
- `task-inherits-from-parent-project` — task with `parent_project:1` ⇒ task viewers are project viewers

---

## Multi-tenancy boundary

**Today:** single tenant, single user. Jason's BD effort within AECOM Digital Infrastructure.

**Phase 10 stance:** add `tenant_id` to every multi-tenant table now, even though it's a constant value. RLS policies enforced. This gets the schema **production-shaped** without requiring a multi-tenant rollout.

Tables that get `tenant_id` (multi-tenant):
- `people`, `projects`, `project_budget_lines`, `tasks`, `pursuits`, `comms_log`, `bl_requests`, `bl_request_contacts`, `bl_submissions`, `bl_submission_lines`, `audit_logs`, `opp_watch_tracks`, `opp_watch_queries`, `opp_watch_results`

Tables that DON'T (system-shape):
- None — every table in the schema is tenant-scoped.

Default tenant for migrated rows: `aecom-bd-jason` (created in `secforge-tenants` Keycloak realm during Phase 10.{N}.1; mirrored as a SpiceDB `organization:aecom-bd-jason` object).

Postgres RLS policy template (per CLAUDE.md):

```sql
ALTER TABLE project_tracker.projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_select ON project_tracker.projects
    FOR ALL TO project_tracker_app
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

The app sets `app.tenant_id` once per request, sourced from the BFF-injected identity headers (the `tenant_id` claim flows from Keycloak realm assignment).

---

## Outbound-secret inventory

| Secret | Used by | Today | After Phase 10 |
|---|---|---|---|
| `SAM_GOV_API_KEY` | `server/src/modules/opp-watch/service.ts:271` and `scripts/opp-poller/poll.mjs:29` — calls `https://api.sam.gov/opportunities/v2/search` | `.env` | OpenBao at `secret/data/apps/project-tracker/sam-gov`, fetched at request time via `apps/lib/secrets/` |
| `DATABASE_URL` | Prisma client | `.env` (with embedded password to local docker-compose Postgres) | Replaced — Prisma connects to the cluster's `secforge-app-db` with credentials minted dynamically by OpenBao via the `project-tracker-readwrite` database role |

That's the entire list. Compare against [`.env.example`](file:///C:/Users/jaupo/Projects/Project%20Tracker/.env.example) — all other env vars are non-secret tuning (`PORT`, `DIGEST_OUTPUT_DIR`, `ENABLE_API_AI=false`, `OPP_POLL_*`).

The `.env.example.from-pf` carries over Proposal Forge's `ANTHROPIC_API_KEY` slot, but **Project Tracker doesn't use it** — CLAUDE.md hard rule: no `api.anthropic.com` calls in the PT backend. AI runs via the MCP server (Week 5) on Jason's Claude subscription, with no API key required. Confirm zero references with:

```
grep -r "ANTHROPIC_API_KEY" "C:/Users/jaupo/Projects/Project Tracker/server" "C:/Users/jaupo/Projects/Project Tracker/scripts"
```

(Should return nothing in `server/` or `scripts/`. The string only appears in `.env.example.from-pf` — a leftover from the PF copy bootstrap that's unused.)

---

## Architectural notes worth surfacing now

### MCP server (Week 5) is a separate question

PT's `server/src/mcp/index.ts` runs an MCP server that Jason's local Claude Code connects to via stdio for AI assistance over PT's data. Once PT's server runs in the cluster, the local-stdio model breaks: Claude Code on Jason's laptop can't pipe stdio into a cluster pod. **Defer** the cluster-MCP question to a follow-up — Phase 10 can ship without the MCP server (or run it locally still, pointed at the cluster's PT API). Open as a Phase 10 follow-up.

### Reports module needs Puppeteer

`server/src/modules/reports/` uses Puppeteer for PDF generation. The container image needs Chromium + the right shared libraries; resource requests need to accommodate the headless browser. The helloworld-backend Dockerfile is the wrong base for this. Plan for a Puppeteer-aware Dockerfile (probably the official `ghcr.io/puppeteer/puppeteer:*` image as base, or alpine + manual chromium install).

### Cron-driven SAM.gov poller

`startScheduler()` at `server/src/index.ts:51` boots a `node-cron` schedule inside the Express process. This is fine for a single replica, but two implications:
- **Single replica only** — same constraint as the BFF per [ADR-0011](../../02-decisions/0011-bff-single-replica-local.md). No cron leader election. Document this in the deploy.
- **Cluster equivalent is a CronJob.** When PT scales (post-local), pull the cron logic out of the Express process and into a separate CronJob pod. For local edition, leave it.

### `Person` ≠ `User`

`Person` is the team roster (colleagues being tracked). The auth subject is `User` (Keycloak). Phase 10 must NOT add password fields to `Person`. Instead: add an optional `keycloak_sub` column on `Person` that links a PT-tracked colleague to their auth identity if/when they log in. The current case (only Jason has an auth identity) means every `Person` row except Jason's stays `keycloak_sub = NULL`.

---

## Cutover plan — Phase 10.1.1 → 10.1.10

Numbered to match the Phase 10 prompt's `Phase 10.{N}.X` structure with `{N}=1` for Project Tracker.

### 10.1.1 — Audit ✅ (this document)

You're reading it.

### 10.1.2 — SpiceDB schema additions

Edit [`infrastructure/spicedb/schema.zed`](../../../infrastructure/spicedb/schema.zed) to add the five `project_tracker/*` definitions above. Add validator tests under `infrastructure/spicedb/tests/project-tracker/`. Apply via `zed schema write`; `zed validate` must pass.

### 10.1.3 — Postgres schema migration ✅ Complete 2026-05-05

In `secforge-app-db`, create schema `project_tracker`. Take PT's [`prisma/schema.prisma`](file:///C:/Users/jaupo/Projects/Project%20Tracker/prisma/schema.prisma):

1. Add `@@schema("project_tracker")` to every model.
2. Drop nothing — there's no User/auth tables to drop. (Confirms PT is the easy one.)
3. Add `tenantId String @map("tenant_id") @db.Uuid` to every model. Backfill default = `aecom-bd-jason`'s UUID for migrated rows.
4. Add Postgres RLS policies per the template above.
5. Generate Prisma migration; apply against `secforge-app-db` using credentials minted via OpenBao (no DATABASE_URL with embedded password in any committed file).
6. `pg_dump` from the local docker-compose `project_tracker` database → `psql` into `secforge-app-db.project_tracker.*`. Transform: add `tenant_id` to every row.

**Closeout (2026-05-05):** Landed in two commits — PT-repo `69f42a7` (Prisma schema edits + Prisma-generated migration `20260505234638_10_1_3_secforge_integration`) and the platform-repo Phase 10.1.3 commit (this commit). All artifacts at [`apps/project-tracker/`](../../../apps/project-tracker/) — see the [README](../../../apps/project-tracker/README.md) for the file layout and the canonical "running the cutover" recipe. Tenant UUID pinned at [`apps/project-tracker/TENANT.md`](../../../apps/project-tracker/TENANT.md) (`833cc9ee-81b6-4e79-a4d7-e104fa37aa12`); never regenerate.

**Deviations from the plan worth noting for Phase 11 (Proposal Forge):**

- The original prompt's `SET LOCAL row_security = off;` to bypass RLS during import does NOT work for non-superusers — Postgres errors with "query would be affected by row-level security policy" instead of silently filtering. The 003-import.sh path uses `SET LOCAL app.tenant_id = '<UUID>';` instead, which engages RLS positively (every row's tenant_id matches the GUC, so WITH CHECK passes). Cleaner because it actually exercises the policy rather than circumventing it.
- pg_dump 16.13 (running in PF's docker-compose) emits `\restrict` / `\unrestrict` directives at start and end of the dump that older psql 16.4 (cluster) chokes on with `invalid command \restrict`. 003-import.sh strips these via sed before applying.
- pg_dump's preamble includes `SET row_security = off;` which is session-level (no LOCAL) and overrides the per-transaction `SET LOCAL app.tenant_id`. 003-import.sh strips this line too.
- pg_dump emits `SELECT pg_catalog.setval('public.<seq>', ...)` calls for BIGSERIAL counters; sed retargets these to `project_tracker.<seq>`.
- The migrate role needs `UPDATE` on sequences (not just `USAGE, SELECT`) because `setval()` is a sequence write. Added to apply.sh's grant step.
- Tables created by the postgres superuser are owned by postgres; the migrate role needs explicit per-table `GRANT SELECT, INSERT, UPDATE, DELETE` (RLS scopes row visibility but doesn't substitute for table-level privileges). Added to apply.sh, with `ALTER DEFAULT PRIVILEGES` to auto-grant on future tables.
- The `_prisma_migrations` table in the local DB is excluded from the dump (`--exclude-table=_prisma_migrations`) — the cluster doesn't track PT's local Prisma history; schema management in the cluster goes through `apps/project-tracker/migrations/00N-*.sql`.

**Verification recorded by 004-verify.sh:**

```
TABLE                           LOCAL    CLUSTER STATUS
people                              5          5 ✓
projects                            3          3 ✓
project_budget_lines                0          0 ✓
tasks                               8          8 ✓
pursuits                            3          3 ✓
comms_log                           2          2 ✓
opp_watch_tracks                    2          2 ✓
opp_watch_queries                   0          0 ✓
opp_watch_results                   0          0 ✓
bl_requests                         0          0 ✓
audit_logs                          0          0 ✓
bl_request_contacts                 0          0 ✓
bl_submissions                      0          0 ✓
bl_submission_lines                 0          0 ✓
TOTAL                              23         23

✓ wrong tenant UUID → 0 rows (RLS filters all rows out)
✓ AECOM UUID → 3 rows (matches source)
✓ GUC unset → 0 rows (fail-closed when middleware forgets to set tenant_id)
```

**Note on data shape:** the PT seed data is sample-shaped (5 people, 3 projects, 3 pursuits, etc.) — PT had no real production data on the local docker-compose volume going into the migration (single-user app, ephemeral seeding pattern). The migration pipeline is therefore proven on synthetic-but-realistic data; Phase 11 (Proposal Forge) will exercise the same pipeline against real production data with potentially-trickier table shapes (PF's audit_logs JSONB column is the obvious risk surface).

### 10.1.4 — Wire BFF-injected identity (mostly additive, since nothing exists to strip)

There is no auth code to delete. Instead:

1. Add `server/src/common/identity.ts` that reads BFF-injected headers (`X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Tenant`, `X-Forwarded-Sub`) into a typed `Identity` object.
2. Add an Express middleware that calls SpiceDB's AuthZEN façade (`/access/v1/evaluation`) before any mutating endpoint runs.
3. For each route in `server/src/index.ts:33-45`, classify the operation:
   - Read endpoints → `permission view`
   - List endpoints → `permission view` on the parent
   - Mutate endpoints → `permission edit`
   - Special cases — `complete` on Task uses `permission complete`; `submit` on BlRequest uses `permission submit`
4. Populate `AuditLog.changedById` from `Identity.sub` (was always null).

### 10.1.5 — Reroute `SAM_GOV_API_KEY` through OpenBao

1. Stand up OpenBao path `secret/data/apps/project-tracker/sam-gov` with the current key value.
2. Stand up SPIFFE-bound JWT auth role `project-tracker` with policy granting read on that path.
3. Modify `server/src/modules/opp-watch/service.ts:271` and `scripts/opp-poller/poll.mjs:29` to fetch the key via `apps/lib/secrets/` instead of `process.env.SAM_GOV_API_KEY`.
4. Remove `SAM_GOV_API_KEY` from `.env.example`. Add a `secforge.local/legacy-secret-env-expires` annotation NEVER — there's no legacy env path here, no escape hatch needed.

### 10.1.6 — Build the BFF

Clone [`apps/helloworld-bff/`](../../../apps/helloworld-bff/) → [`apps/project-tracker-bff/`](../../../apps/). Adjust:

- Keycloak client: `project-tracker-bff` (the skeleton already exists from Phase 3).
- Backend upstream: `project-tracker-backend.app.svc.cluster.local:3002`.
- Path prefix served: `/api/tracker/*` (PT's existing route shape — minimal frontend churn).
- Login redirect URL: `https://project-tracker.secforge.local/`.
- DPoP htu: same canonicalization helper as helloworld-bff (lesson from Phase 9).

### 10.1.7 — Build container images

1. PT backend Dockerfile: base from `ghcr.io/puppeteer/puppeteer:*` to handle Reports module. Multi-stage: deps → tsc → final.
2. PT frontend: nginx-served static build (same pattern as helloworld-frontend).
3. PT BFF: same pattern as helloworld-bff, distroless.
4. All three signed with cosign; SBOMs generated; pushed to local registry.

### 10.1.8 — Deploy

Stand up under `infrastructure/project-tracker/` (mirroring the helloworld pattern):
- Namespace: `app` (existing).
- ServiceAccount + ClusterSPIFFEID.
- BFF + backend + frontend Deployments (single replica each per ADR-0011 + the cron-leader constraint).
- Services + Ingress at `project-tracker.secforge.local`.
- AuthorizationPolicy: BFF → backend, prometheus → backend `/metrics`.
- NetworkPolicy: backend → secforge-app-db; backend → SpiceDB; backend → OpenBao; backend → `api.sam.gov` (egress allow).

### 10.1.9 — Frontend pickups

PT's frontend has no login page to delete. Additions:
- `client/src/lib/api.ts` — point `VITE_API_BASE_URL` at the BFF (`https://project-tracker.secforge.local/api/tracker`). The BFF strips its own auth dance and forwards to backend.
- `AppShell.tsx` — add a small "logged in as Jason / sign out" affordance in the header. Sign-out calls BFF's `/auth/logout`.
- No 401 handling needed yet (single-user; Jason is always authorized once logged in). Add it when colleagues join.

### 10.1.10 — Verification + sign-off

- All routes under `/api/tracker/*` reachable through the BFF (jason logged in).
- AuthZEN evaluation gates every mutating endpoint (alice/bob test users denied per fixture).
- `AuditLog.changedById` populated on every mutation.
- SAM.gov poller runs successfully against the OpenBao-sourced key.
- Reports module renders a PDF + DOCX.
- Wazuh receives login + mutation events from PT (after operator-backlog #17 + #18 close).
- Local docker-compose `project_tracker` Postgres torn down; data verified in `secforge-app-db`.
- Tagged `project-tracker-v0.5.0` once green.

---

## Open questions / follow-ups for after Phase 10.1

1. **MCP server reachability from local Claude Code → cluster-deployed PT.** Stdio model breaks. Options: keep a thin local-only MCP shim that proxies to the cluster API; or expose a bounded set of MCP-over-HTTP endpoints. Decide with a small ADR.
2. **Multi-replica when colleagues join.** Cron in Express + single replica is fine for now; the cron has to move to a CronJob pod when scaling.
3. **`Person.keycloak_sub` linking.** UI flow for connecting a roster `Person` to their first Keycloak login — defer until colleagues are actually invited.
4. **Pursuit-promotion-creates-Project flow.** Today this is a button that copies fields. After Phase 10 it should also seed SpiceDB tuples (jason owner-of new project) so the AuthZEN check works on day one.
5. **OppWatch result promotion to Pursuit.** Same SpiceDB seeding concern.

These don't block the cutover; they're notes for Phase 10.1.10 + Phase 11.

---

## Confidence and risks

**High confidence on:**
- Outbound secret inventory (only SAM.gov key)
- Auth strip (nothing to strip)
- Schema mapping (Prisma-to-Postgres-with-tenant-id is mechanical)
- BFF pattern reuse (helloworld-bff is a proven template)

**Medium confidence on:**
- Puppeteer-in-container resource sizing — first time we ship a heavy dependency at this layer
- Cron-in-Express single-replica constraint — works locally but is a smell

**Lower confidence on:**
- MCP server reachability post-cutover. Probably needs a follow-up ADR before Week 5 PT work resumes.

Risks ranked: MCP-reachability > Puppeteer sizing > cron-replica constraint > everything else.
