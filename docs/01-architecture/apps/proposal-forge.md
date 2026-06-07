# Proposal Forge — secforge-prod Migration Audit

> **Phase 0 audit output.** Maps the existing Proposal Forge codebase onto the
> **live bare-metal** SecForge platform and defines the phased cutover. Source
> repo: `C:\Users\jaupo\Projects\Proposal Forge\`.
>
> Last updated: 2026-06-02 (audit).
>
> **Companion docs:** [realm-to-app matrix](../01a-realm-to-app-matrix.md) ·
> [ecosystem SpiceDB schema](../../../platform/manifests/spicedb/ecosystem-schema.zed) ·
> [project-tracker audit](./project-tracker.md) (sister app, same stack)

---

## Pattern note — this follows the LIVE Member Hub shape, not the local edition

The earlier [phase-10 integrate-proposal-forge prompt](../../99-archive/05-claude-code-prompts/phase-10-integrate-proposal-forge-project-tracker.md)
and the project-tracker audit were written for the **retired local edition**
(separate BFF deployment, shared `secforge-app-db`, `secforge.dev`, mkcert,
`infrastructure/spicedb`). The live bare-metal platform does **not** use that
shape. Proposal Forge clones the **Member Hub** production pattern instead:

| Concern | Local-edition plan (stale) | Live pattern (this doc) |
|---|---|---|
| Auth edge | separate `*-bff` pod injecting headers | **in-app OIDC** (AuthCode+PKCE) in the Express process |
| Database | shared `secforge-app-db`, per-app schema | **per-app CNPG cluster** `proposal-forge-db` |
| Secrets | `apps/lib/secrets` Go library | **OpenBao → VSO-rendered Secrets** + spiffe-helper sidecar for Transit |
| Files | n/a | **MinIO + SSE-S3**, bucket-scoped creds via VSO |
| Domain | `secforge.dev`, mkcert | `pf.secforge.dev`, LE via DNS-01 |
| Exposure | public ingress | **tailnet-only** (CGNAT whitelist + Kyverno enforce) |
| Images | local registry, local cosign key | **GHCR digest-pinned + cosign keyless**, Kyverno-verified |

The manifest template is `platform/manifests/member-hub/*` (14 files). The
SpiceDB definitions already exist as `proposalapp/*` in `ecosystem-schema.zed`.

---

## Migration decisions (confirmed 2026-06-02)

| Decision | Choice | Consequence |
|---|---|---|
| **Identity** | Full ecosystem — Keycloak OIDC + SpiceDB + app-activation gate | Delete standalone Passport/JWT; PF becomes `proposalapp` |
| **Realm** | `platform` (operator/staff) — tailnet-only for now | Defer `secforge-tenants` dual-registration until/if tenant-facing |
| **AI** | Gemini now; provider layer kept pluggable for Claude/OpenAI later | `GEMINI_API_KEY` → OpenBao; add OpenAI provider; make selection runtime config |
| **Storage** | MinIO + SSE-S3 | multer disk → S3 client; four `data/` dirs become key prefixes |
| **ORM** | Keep Prisma (`migrate deploy` in a Job) | Rewriting 26 clean migrations to raw SQL would *add* risk, not remove debt |
| **PDF** | Keep Puppeteer in a hardened Chromium image, `--no-sandbox` | Pod is the sandbox (non-root, caps dropped, seccomp, RO-rootfs) |
| **Access** | No public surface anywhere | nginx ingress + `whitelist-source-range: 100.64.0.0/10` + Kyverno |

---

## Current state — what we're migrating

**Stack:** Node 20 + Express 5 + TypeScript (strict) · Prisma 6 + Postgres 16 ·
React 18 / Vite / Zustand / Tailwind / shadcn / TipTap. Single process serves the
API (`/api/v1/*`) **and** the built SPA from `client/dist` — same shape as
Member Hub, so no separate frontend pod.

**Already strong (security baseline carried over):** Helmet CSP locked to
`'self'` (`object-src 'none'`, `frame-ancestors 'none'`), CORS `origin:false`
in prod, Zod input validation, Pino logging, `sanitize-html`, all-UUID PKs,
`Decimal(10,2)` money, 26 locked Prisma migrations.

**Gaps closed by this migration:** no Dockerfile, no image pipeline, no org/
tenant boundary, standalone auth, local-disk storage, plaintext `.env` secrets,
single combined health endpoint.

---

## Domain model (carried over from `prisma/schema.prisma`)

Full fidelity lives in
[`Proposal Forge/prisma/schema.prisma`](file:///C:/Users/jaupo/Projects/Proposal%20Forge/prisma/schema.prisma)
(30 models, 538 lines) — don't duplicate it; this is the orientation map.

| Cluster | Models | Notes |
|---|---|---|
| **Auth (transformed)** | `User` | Drop `password_hash`/`role`/`is_active`; add `keycloak_sub`; becomes a thin profile keyed to Keycloak. See § Auth transform. |
| **Project root** | `Project`, `ProjectMember`, `ProjectNote`, `ProjectDocument` | `Project` = one proposal effort = `proposalapp/proposal` in SpiceDB. `ProjectMember.role ∈ {OWNER,EDITOR,REVIEWER,VIEWER}` → proposal relations. |
| **RFP + tasks** | `RfpDocument`, `ExtractedTask` (self-referential subtasks) | RFP text + AI summary/intent/requirements columns. |
| **Pricing inputs** | `DisciplineGroup`, `LaborCategory`, `RateCard`, `PersonnelAssignment` | Rate cards are **company-specific** → org-scoped (not global). |
| **Travel** | `TravelPlan`, `Trip`, `TripPersonnelAssignment`, `TripCostLine` | GSA per-diem driven. |
| **Cost build-up** | `AdditionalCost`, `Subcontractor`, `ProfitFeeItem`, `PricingLineItem` | `PricingLineItem` = task × personnel matrix cell. |
| **Proposal output** | `ProposalSection`, `ProposalSectionReference`, `ProposalTemplate`, `SectionGuidanceTemplate`, `AnalysisGuidanceTemplate` | Narrative sections + AI guidance singletons. |
| **Asset library** | `Asset`, `ProjectAsset` | Org-wide reusable content (resumes, past-perf, boilerplate). Files in MinIO. |
| **Custom fields** | `CustomFieldDefinition`, `CustomFieldValue` | `allowedRoles UserRole[]` → re-express against ecosystem roles. |
| **System** | `AuditLog`, `SystemSetting`, `PerDiemCache` | `AuditLog.userId` → Keycloak `sub`. `PerDiemCache` is **global** (GSA rates are universal). |

---

## Permissions model — SpiceDB translation

PF today has **two RBAC layers**, both enforced via `requireRole`/`requireMinRole`
on the system role only (project-member roles exist in data but enforcement is
partial):

- **System role** (`User.role`): `ADMIN(5) > MANAGER(4) > DRAFTER(3) > REVIEWER(2) > VIEWER(1)` — hierarchical, org-wide capability tier.
- **Project role** (`ProjectMember.role`): `OWNER / EDITOR / REVIEWER / VIEWER` — per-project.

The ecosystem schema **already models this** — `definition proposalapp/proposal`
exists in [`ecosystem-schema.zed`](../../../platform/manifests/spicedb/ecosystem-schema.zed)
with `owner/editor/reviewer/viewer + app->view/administer` cascades, plus the
`app` (per-org `app:proposalapp:<orgId>`) and `organization` definitions. So
Phase 3 is mostly **wiring tuples + tests**, not new schema.

### Role mapping — PF → ecosystem

**Project role → `proposalapp/proposal` relation (direct):**

| PF project role | `proposalapp/proposal#…` | Grants |
|---|---|---|
| OWNER | `owner` | view, edit, review, approve, delete |
| EDITOR | `editor` | view, edit |
| REVIEWER | `reviewer` | view, review, approve |
| VIEWER | `viewer` | view |

**System role → org / app relations (org-wide tier):**

| PF system role | Maps to | Rationale (per `architecture.md` matrix) |
|---|---|---|
| ADMIN | `organization#local_administrator` + `app:proposalapp#administrator` | manage users, system settings, rate cards, every project |
| MANAGER | `app:proposalapp#creator` + `#editor` + `#exporter` | create/delete projects, edit, export, manage rate cards |
| DRAFTER | `app:proposalapp#editor` + `#exporter` (+ per-proposal `editor`) | edit projects they're a member of, export |
| REVIEWER | `app:proposalapp#approver` + `#exporter` | review + export, no edit |
| VIEWER | `app:proposalapp#viewer` | read-only |

> These direct mappings are the **day-1** wiring. In the ecosystem's three-layer
> model they ultimately become **org-defined role bundles** (Layer 2,
> `ecosystem_control.org_roles`) that expand into the same app relations — see
> ADR-0026. We seed the direct relations first; the role-builder bundles come
> when/if PF goes multi-org.

### Validator tests to add (`platform/manifests/spicedb/tests/proposalapp/`)

Mirror the existing `project-tracker/` test set:
- `owner-can-edit-proposal`, `viewer-cannot-edit`, `reviewer-can-approve-not-edit`
- `no-relation-denied`, `org-admin-cascades-to-all-proposals`
- `app-not-activated-denied` (org without the `app` relation gets nothing)

---

## Multi-tenancy boundary — the biggest schema lift

**Today:** Proposal Forge has **no organization concept at all.** Every row is
global. There is no `tenant_id`, no org table, no isolation.

**Target:** introduce an org boundary now so the schema is production-shaped,
even though there's a **single internal org** at launch (operator + any staff,
on the `platform` realm, tailnet-only).

- One org created in Keycloak/Control + mirrored as SpiceDB `organization:<uuid>`
  with the mandatory `organization:<uuid>#platform@platform:ecosystem` back-link
  (omitting it hides the org from ecosystem admins — this bit the signup wizard).
- That org gets `proposalapp` activated: `organization:<uuid>#app@app:proposalapp:<uuid>`.
- Add `org_id UUID` (`@map("org_id") @db.Uuid`) to **every business table**;
  backfill all migrated rows to the single default org's UUID. Pin that UUID in
  `apps/proposal-forge/TENANT.md` — never regenerate (PT precedent).
- **Global (no `org_id`):** `per_diem_cache` only — GSA rates are universal and
  shared across orgs is correct + efficient.
- **Postgres RLS** on every org-scoped table, keyed to a per-request GUC the app
  sets from the active-org context:

```sql
ALTER TABLE proposal_forge.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE proposal_forge.projects FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON proposal_forge.projects
    FOR ALL TO proposal_forge_app
    USING (org_id = current_setting('app.org_id', true)::uuid)
    WITH CHECK (org_id = current_setting('app.org_id', true)::uuid);
```

> **Data-import RLS gotchas (proven on the Project Tracker cutover — read before Phase 4):**
> `SET row_security = off` **fails for non-superusers** ("query would be affected by
> RLS"); use `SET LOCAL app.org_id = '<uuid>'` so every row's `org_id` matches the GUC
> and `WITH CHECK` passes. pg_dump ≥16.x emits `\restrict`/`\unrestrict` and a session-level
> `SET row_security = off` that older cluster `psql` chokes on / that overrides your
> `SET LOCAL` — strip both with `sed`. The migrate role needs explicit per-table
> `GRANT SELECT,INSERT,UPDATE,DELETE` (RLS scopes rows, not table privilege).
> Cross-org `UPDATE`s under the CNPG cluster user need `ALTER TABLE … NO FORCE/FORCE`
> bracketing (`SET row_security = off` 403s). See project memory
> `project_migration_force_rls_bypass`.

---

## Auth transform (`User` table)

Delete from `User`: `password_hash`, `role` (→ SpiceDB), `is_active` (→ Keycloak).
Add: `keycloak_sub String @unique`. Keep `email`, `name` (cached profile +
display prefs only). Populate `keycloak_sub` by email-matching existing rows to
Keycloak users — for the internal launch that's just the operator. FKs that
reference users (`created_by_id`, `author_id`, `uploaded_by_id`, `AuditLog.user_id`)
stay, now pointing at the thin profile keyed by `sub`.

**Code deletions (Phase 5):** `server/middleware/auth.ts`,
`server/services/auth.service.ts`, `server/routes/auth.routes.ts` (register/
login/logout/refresh), bcrypt + jsonwebtoken usage, the `pf_token` cookie, and
the client login/register pages. **Replace with:** in-app OIDC (AuthCode+PKCE)
like Member Hub's `src/modules/auth`, an active-org cookie + same-origin proxy
to Control's API, and a per-request SpiceDB `CheckPermission` middleware that
runs before every mutating handler (read = `view`, mutate = `edit`, export =
`export`, review/approve = `review`/`approve`).

---

## Outbound-secret inventory

`.env` is gitignored and **never entered git history** (verified
`git log --all -- .env` → empty) — so no historical leak. The live values still
get **rotated on cutover** as hygiene, since they move to OpenBao and are
regenerable.

| Secret | Used by | Today | After migration |
|---|---|---|---|
| `GEMINI_API_KEY` | `server/services/ai/providers/gemini-provider.ts` | `.env` (live key) | OpenBao `secret/apps/proposal-forge/gemini` → VSO env. **ROTATE.** |
| `GSA_API_KEY` | `server/services/gsa.service.ts` (api.gsa.gov per-diem) | `.env` (live key) | OpenBao `secret/apps/proposal-forge/gsa` → VSO env. **ROTATE.** |
| `JWT_SECRET` | `server/services/auth.service.ts` | `.env` | **DELETED** — Keycloak owns tokens. |
| `ANTHROPIC_API_KEY` | anthropic-provider (dormant) | empty | OpenBao path reserved for the later Claude/OpenAI iteration. |
| `DATABASE_URL` | Prisma | `.env` (local pw) | CNPG-rendered `proposal-forge-db-app` Secret (`uri` key). |
| `OIDC_CLIENT_SECRET` | new (in-app OIDC) | — | OpenBao → VSO. Keycloak `proposal-forge` client. |
| `SESSION_KEY` | new (OIDC session cookie) | — | OpenBao → VSO. |

Egress required: **Gemini** (`generativelanguage.googleapis.com`) and **GSA**
(`api.gsa.gov`) over the `allow-egress-internet-https` NetworkPolicy; everything
else is in-cluster (Keycloak, SpiceDB, Control, OpenBao, MinIO, OTel).

---

## AI provider — pluggable, Gemini-first

The provider abstraction already exists
(`server/services/ai/ai-provider.ts` → `gemini` / `anthropic` / `ollama`
implementations behind a common `AIProvider` interface). Work:

1. **Gemini active** via `GEMINI_API_KEY` from VSO; `GEMINI_MODEL=gemini-2.5-flash`.
2. **Add an OpenAI provider** (`openai-provider.ts`) implementing the same interface
   (the `openai` npm package is already a dependency, used today only to point at Ollama).
3. **Make selection runtime config** — move `AI_PROVIDER` + model names out of
   pure env into a `SystemSetting` row so swapping to Claude/OpenAI is a config
   change, not a redeploy. Keys land in OpenBao as each provider is enabled.
4. Ollama paths stay in code but are inert in-cluster (no GPU on the box).

---

## Container & PDF

- **Dockerfile (new):** multi-stage — `npm ci` + `prisma generate` → build client
  (Vite) + server (tsc) → runtime. Must bundle Chromium for Puppeteer, so the
  runtime base is **not** distroless: use a slim Node base with
  `chromium`/`chromium-headless-shell` + the puppeteer-required shared libs, run
  as **non-root (uid 65532)**, `readOnlyRootFilesystem` with writable `/tmp`,
  drop ALL caps, seccomp `RuntimeDefault`. Puppeteer launches headless with
  `--no-sandbox` — acceptable because the **pod** is the sandbox.
- **Migrations bundled** in the image so the migration Job runs `prisma migrate deploy`.
- **Resource sizing:** Chromium is memory-hungry — budget `requests: 256Mi`,
  `limits: 1Gi` (vs Member Hub's 512Mi), revisit after first export load test.
- **Health split:** today there's one `GET /api/v1/health`. Add `/healthz`
  (liveness — process up) and `/readyz` (readiness — DB + MinIO reachable) to
  match the Member Hub probe shape.

---

## Cutover plan — phases

Maps to the migration-plan phases agreed 2026-06-02. Artifacts land under
`apps/proposal-forge/` in the platform repo + the Proposal Forge repo itself.

### P0 — Audit + repo bootstrap ✅ (this doc)
- This document. Create GHCR repo + git remote for Proposal Forge (commits from **Windows**).
- Mark the phase-10 prompt superseded by this doc.

### P1 — Containerize + sign
- Dockerfile (above) + `/healthz` + `/readyz`.
- Self-hosted-runner GHA workflow (`runs-on: [self-hosted, secforge]`): Trivy/Grype
  CRITICAL gate, **cosign keyless** sign (explicit `--registry-username/-password`
  per the Docker-29 quirk), push digest-pinned `ghcr.io/jaupole/proposal-forge`.

### P2 — Keycloak client (codified)
- Add `proposal-forge` (OIDC+PKCE, confidential) + optional `proposal-forge-admin`
  (service-account) to `platform-realm.yaml` (realm-import).
- **Self-audience mapper** + `oidc-sub-mapper` (both are repeat traps); cross-audience
  to `control` (PF calls Control `/me` for active-org).
- Publish client secret → OpenBao → VSO via the `05l`-style bridge. Never to terminal.

### P3 — SpiceDB tuples + tests
- `proposalapp/proposal` already defined. Add `proposalapp/asset` only if asset-level
  sharing is needed (else gate assets at `app->view/administer`).
- Seed day-1 tuples: org back-link to platform, `proposalapp` app-activation,
  operator as `organization#administrator`. Port Member Hub's **app-activation
  middleware** (the PT/PF backlog item).
- Validator tests under `tests/proposalapp/`; `zed validate` green.

### P4 — Data layer
- `proposal-forge-db` CNPG cluster + scheduled backup → MinIO (clone member-hub `02`/`07`).
- Prisma schema edits: drop auth columns, add `org_id` + RLS, `@@schema("proposal_forge")`.
- Migration Job `prisma migrate deploy` (clone member-hub `08`, `backoffLimit:0`, wait-for-db).
- Data import from local docker-compose Postgres (heed the RLS/pg_dump gotchas above).
- MinIO bucket `proposal-forge-files` (versioned + SSE-S3) + bucket-scoped key via VSO.

### P5 — App code refactor (largest lift)
- Delete local auth (above); add in-app OIDC + active-org cookie + same-origin proxy.
- Per-request SpiceDB checks on every route.
- **multer → MinIO (S3)** for uploads/assets/templates/exports.
- Secrets via VSO env; pluggable AI (Gemini live, OpenAI added); `NODE_EXTRA_CA_CERTS`
  (internal CA), `TRUST_PROXY=1`.

### P6 — K8s manifests + tailnet exposure
- Clone the 14 member-hub manifests, adapted (namespace PSS `restricted`, SA
  `automount:false`, VSO bindings, NetworkPolicies incl. Gemini+GSA egress,
  objectstore, scheduled backup, migration Job, openbao-CA configmap,
  spiffe-helper config, deployment, services).
- **Tailnet-only ingress** `pf.secforge.dev` + `whitelist-source-range:
  100.64.0.0/10`; **add `pf.` to `10a` `ADMIN_HOSTNAME_PREFIXES` +
  the Kyverno `admin-allowlist-policy.yaml`**. No public A record; LE via DNS-01;
  operator hosts-file → tailnet IP.
- Apply only via `apply-manifest.sh` (envsubst) — never raw `kubectl apply -f`.

### P7 — Observability
- Promtail label, OTel endpoint, Grafana dashboard (req/err rate, latency,
  SpiceDB deny rate, OpenBao fetch rate), Wazuh rules (auth failures, SpiceDB denies).

### P8 — Verify, decommission, document
- E2E: passkey sign-in (name from Keycloak), org/project create, RFP wizard with
  Gemini, DOCX/XLSX/PDF export, cross-user 403 visible in observability.
- After ~1wk soak: `docker compose down -v`, archive the old compose file, update
  PF `CLAUDE.md` (strip Passport/JWT), write `docs/03-runbooks/proposal-forge-operations.md`,
  update PLAN.md + realm matrix + API-security tracker + operator backlog.

---

## Confidence & risks

**High confidence:** SpiceDB model (already designed as `proposalapp/*`); image
pipeline + manifest set (member-hub is a proven template); Prisma `migrate deploy`
as a no-drift path.

**Medium confidence:** the no-org → org refactor + RLS across ~28 tables (largest
schema change; real production data, unlike PT's synthetic set — the JSONB
`analysis_results` / `audit_log.details` columns are the trickiest import surface);
Puppeteer-in-container resource sizing.

**Lower confidence:** auth strip blast radius — PF's auth is genuinely woven
through (unlike PT, which had none). Every route currently assumes `req.user`
from the `pf_token` cookie; swapping to OIDC + SpiceDB touches all 24 route files.

Risk order: **auth strip > org/RLS refactor > Puppeteer sizing > everything else.**
