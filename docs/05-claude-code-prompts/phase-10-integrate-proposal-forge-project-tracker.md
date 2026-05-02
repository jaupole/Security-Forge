# Phase 10 — Integrate Proposal Forge and Project Tracker

> **Navigation:** ⬅ [Previous: Phase 9 — Hello World](./phase-09-hello-world.md) · [Next: Phase 11 — Develop Additional Apps](./phase-11-develop-apps.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 9 · Phase 6b-2 (outbound secrets pattern — apps need it for Anthropic/OpenAI/GSA/etc.)
> **Blocks:** Phase 11
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ Not started. Order: Project Tracker first (smaller, single-user, fewer outbound secrets), Proposal Forge second.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 3-5 weeks (mostly per-app refactoring; the platform integration pattern itself is a few days per app)

**Prerequisites:** Phases 1-9 complete, including 9.12 teardown and 9.13 cleanup verification. The cluster has no Hello World residue. The skeleton clients `proposal-forge-bff` and `project-tracker-bff` exist in Keycloak from Phase 3.

---

## Goal of this phase

Bring the two existing applications — **Proposal Forge** (`C:\Users\jaupo\Projects\Proposal Forge`) and **Project Tracker** (`C:\Users\jaupo\Projects\Project Tracker`) — into the SecForge ecosystem so they authenticate via Keycloak, authorize via SpiceDB, source secrets from OpenBao, and run inside the Istio mesh.

**This is not a rewrite.** Both apps are working Node/Express/TypeScript/Prisma/React systems. We are stripping out their local auth (Passport.js + JWT in cookies), putting them behind their respective BFFs, and migrating their data into the platform's Postgres. The product code stays. The auth/secrets/infra layer changes.

---

## Why both apps in one phase

The two apps share the same stack (Node 20 + Express + TypeScript + Prisma + Postgres + React + Vite + Tailwind + shadcn/ui), so the integration playbook is genuinely identical for both. Doing them together amortizes:

- The "remove local auth, trust BFF-injected identity headers" refactor pattern
- The Prisma → multi-tenant Postgres migration scaffold
- The frontend "no more login form, just a 'sign in' button that hits the BFF" change
- The shared SpiceDB schema additions (`organization`, `proposal`, `project`, `pursuit`, `task`)

The two apps **do not share runtime state** (per Project Tracker's CLAUDE.md hard rules) — they get separate BFFs, separate Postgres schemas, separate Keycloak clients, separate ingresses.

---

## Source-of-truth references

- Proposal Forge: `C:\Users\jaupo\Projects\Proposal Forge\CLAUDE.md`, `docs/architecture.md`, `docs/database-schema.md`, `prisma/schema.prisma`
- Project Tracker: `C:\Users\jaupo\Projects\Project Tracker\CLAUDE.md`, `docs/`, `prisma/schema.prisma`
- Reference integration: `apps/helloworld-bff/`, `apps/helloworld-backend/` (retired but kept as the canonical pattern)
- API auth library: `apps/lib/api-auth/` (Phase 6b-1)
- Outbound secrets library: `apps/lib/secrets/` (Phase 6b-2)

---

## What you (the human) need to do first

1. Confirm Phase 9.13 cleanup is verified.
2. Decide which app integrates first. **Recommendation: Project Tracker.** It's single-user, smaller, and its CLAUDE.md hard-rule "no Anthropic API calls in backend" means it has fewer outbound-secret integrations than Proposal Forge — simpler first pass through the secrets-library migration. Proposal Forge integrates second, reusing Project Tracker's now-proven pattern.
3. Back up both apps' current Postgres data (`pg_dump` from each app's docker-compose) — Phase 10.6 imports it into the platform's `secforge-app` Postgres. The local docker-compose'd databases stay running until import is verified, then are decommissioned.
4. Inventory Proposal Forge's outbound secrets: Anthropic API key, Google Generative AI key, OpenAI key, GSA API key (if used). These all move to OpenBao via the Phase 6b-2 secrets library. Get the current values handy — this is the **last time** they touch a `.env` file.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code. **Do this twice — once with `{APP}=project-tracker`, then once with `{APP}=proposal-forge`.** Do them sequentially, not in parallel: Project Tracker first, full sign-off, then Proposal Forge.

---

```
We're starting Phase 10 of the SecForge Local Edition platform build, integrating {APP} into the platform. Read CLAUDE.md, PLAN.md, docs/05-claude-code-prompts/phase-10-integrate-proposal-forge-project-tracker.md, docs/01-architecture/04-bff-pattern.md, docs/01-architecture/06-api-pattern.md, and the {APP} CLAUDE.md at C:\Users\jaupo\Projects\{APP_DIR}\CLAUDE.md before doing anything.

The goal is to put {APP} behind its BFF, swap its local auth for platform auth, migrate its Postgres into secforge-app, route its outbound secrets through OpenBao, and deploy it into the cluster. The product code is not being rewritten. Auth, secrets, and infrastructure are.

## Phase 10.{N}.1 — Audit the existing app

Walk the {APP} repo and document:
- All authentication code paths (passport.js setup, JWT signing, cookie issuance, login/logout/session middleware) — these all get DELETED in 10.{N}.4
- All outbound-secret consumers (Anthropic SDK, OpenAI SDK, Google AI SDK, any third-party API key) — these all get rerouted through `apps/lib/secrets/` in 10.{N}.5
- Prisma schema — every table, every relation, every index — this gets migrated into secforge-app Postgres in 10.{N}.6
- Frontend authentication UI (login page, register page, "forgot password," profile page) — login/register get DELETED, profile re-fetches from BFF /api/me

Output: docs/01-architecture/apps/{APP}.md with sections:
- Domain model (carry over from app's existing docs)
- Permissions model — translate the app's existing role checks into SpiceDB tuples
- Multi-tenancy boundary (Project Tracker: single-user-for-now-but-tenant-shaped; Proposal Forge: per-org)
- Outbound-secret inventory
- Cutover plan (this phase's checklist)

## Phase 10.{N}.2 — SpiceDB schema additions

Edit infrastructure/spicedb/schema.zed to add the {APP}-specific definitions. Patterns:

For Project Tracker:
  definition organization { ... } (already exists from Hello World era — reuse)
  definition project { relation owner; relation member; relation viewer; permission view; permission edit; ... }
  definition pursuit { ... similar ... }
  definition task { relation assignee; relation owner; permission view; permission edit; permission complete; ... }

For Proposal Forge:
  definition organization { ... reuse }
  definition proposal { relation author; relation collaborator; relation viewer; permission view; permission edit; permission export; ... }
  definition rfp { relation owner; permission view; permission edit; ... }

Add validator tests under infrastructure/spicedb/tests/{APP}/ covering: owner-can-edit, viewer-cannot-edit, no-relation-denied, org-admin-cascades, share-grants-view.

Apply via `zed schema write` and verify with `zed validate`.

## Phase 10.{N}.3 — Postgres schema migration

Each app gets its own schema in `secforge-app-db`:
  - Project Tracker: schema `project_tracker`
  - Proposal Forge: schema `proposal_forge`

Steps:
  1. Take Prisma schema from C:\Users\jaupo\Projects\{APP_DIR}\prisma\schema.prisma
  2. Add `@@schema("...")` directives to every model, mapping them into the per-app schema
  3. Drop the app's local user/auth tables — they're replaced by Keycloak (the app's `User` model becomes a thin local table keyed by Keycloak `sub`, holding only app-specific fields like display preferences; auth fields like password_hash are deleted)
  4. Add `tenant_id` to every multi-tenant table; add Postgres RLS policy per CLAUDE.md
  5. Generate migration via Prisma; apply via `npx prisma migrate deploy` against secforge-app-db (with credentials fetched from OpenBao via the secrets library — no DATABASE_URL with embedded password in any committed file)
  6. Import the existing data: `pg_dump` from the app's local Postgres → `psql` into secforge-app-db, transforming rows to match the new schema (drop the password_hash column, populate tenant_id from a default-org-for-jason, etc.)

Commit migration scripts under apps/{APP}/migrations/ alongside any data-transformation SQL.

## Phase 10.{N}.4 — Strip local auth, accept BFF-injected identity

This is the biggest single refactor. Touch every server file that does auth.

Delete:
  - server/middleware/auth.ts (passport setup)
  - All passport strategies (local, JWT)
  - JWT signing utilities
  - bcrypt/password hashing code
  - /auth/login, /auth/register, /auth/logout, /auth/refresh routes
  - Cookie-parser session-cookie code (cookies handled by BFF now)
  - User registration UI in the frontend
  - Login page in the frontend (replace with a "Sign in with SecForge" button that just navigates to /login on the BFF)

Replace with:
  - One middleware that reads BFF-injected headers (the BFF puts Keycloak `sub`, email, display name into trusted forward headers after validating the session — exact header names from docs/01-architecture/04-bff-pattern.md)
  - Use `apps/lib/api-auth/` to validate the JWT + DPoP that the BFF forwards (the BFF mints DPoP-bound tokens per Phase 6b)
  - Every protected route calls into the api-auth middleware → AuthZEN check → handler
  - The User table now stores only Keycloak `sub` + display preferences; lookups are by `sub`

Test locally before deploy: pointing the local app's frontend at a stub that injects the BFF headers should still serve all pages.

## Phase 10.{N}.5 — Route outbound secrets through OpenBao

The canonical migration runbook is [docs/03-runbooks/migrate-env-to-openbao.md](../03-runbooks/migrate-env-to-openbao.md) (shipped Phase 6b-2 commit 6); follow it step-by-step. Quick recap:

For every credential in the app's existing `.env`, write it into OpenBao under the per-integration KV path. **Group fields under one integration**, don't make a separate path per key:

```bash
bao kv put secret/apps/{APP}/anthropic api_key=<...>
bao kv put secret/apps/{APP}/openai    api_key=<...> organization_id=<...>   # Proposal Forge only
bao kv put secret/apps/{APP}/sendgrid  api_key=<...> from_email=<...>
```

Wire `apps/lib/secrets/` at startup, mirroring [apps/helloworld-bff/admin.go](../../apps/helloworld-bff/admin.go) (the Phase 6b-2 reference adopter):

```go
client, err := libSecrets.New(bootstrap, libSecrets.Config{
    AppName:  "{APP}",
    CacheTTL: 5 * time.Minute,
    Hardened: true,
})
```

Replace every `process.env.X_API_KEY` / `os.Getenv("X_API_KEY")` lookup with the library's `GetField` + `Secret.Use` pattern:

```go
// before
key := os.Getenv("ANTHROPIC_API_KEY")
err := callAnthropic(key)

// after
secret, err := client.GetField(ctx, "anthropic", "api_key")
if err != nil { return err }
err = secret.Use(func(b []byte) error {
    return callAnthropic(string(b))
})
// Secret is best-effort-zeroed on Use return.
```

The library handles SPIFFE-JWT auth to OpenBao, TTL caching, and silent refresh. The app code never sees a raw KV read. The `Secret` type's `String()` and `MarshalJSON()` return `[redacted]` so accidental `fmt.Printf`/`json.Marshal` won't leak the value.

**Database credentials**: fetch dynamic Postgres credentials via `client.GetDynamic(ctx, "<role>")` at startup. Per-pod credentials, lease-bound TTL, library refreshes transparently. The `DynamicCredential.DSN(template)` helper assembles the connection string without exposing the password to the call site.

**Hardened mode default**: new apps get `Hardened: true` per ADR-0013 § 7. `GetField` returns `Secret` (not `string`); call sites MUST consume via `Use` or one of the bundled accessor helpers (`HTTPHeader`, `BasicAuth`, `DSN`).

After cutover:
  - The .env file in the repo is DELETED, not gitignored — it must not exist
  - .env.example exists and contains ONLY non-secret config (PORT, NODE_ENV, etc.) per [`templates/app-repo/.env.example`](../../templates/app-repo/.env.example)
  - The pre-commit + CI workflow from `templates/app-repo/` is installed in the {APP} repo per [docs/03-runbooks/new-app-bootstrap.md](../03-runbooks/new-app-bootstrap.md) and [docs/03-runbooks/ci-secrets-check.md](../03-runbooks/ci-secrets-check.md)
  - The `apps/lib/errreport/` `ScrubbingReporter` is wired into the app's error path (mirror [apps/helloworld-bff/errreport.go](../../apps/helloworld-bff/errreport.go))
  - Verify `git log -p -- .env .env.*` for the app's history shows every value that was ever committed; **rotate every credential whose value appears anywhere in history** per ADR-0013 § Pre-migration checklist
  - Run `bash infrastructure/secrets-guardrails/verify/run-all.sh` from the platform repo; expect 9/9 PASS

## Phase 10.{N}.6 — Containerize, sign, deploy

Build:
  - apps/{APP}/Dockerfile.server — multi-stage, distroless, non-root
  - apps/{APP}/Dockerfile.client — Vite build → static assets baked into BFF image (or served from a separate nginx pod, your call — recommend baking into BFF for parity with Hello World pattern)
  - Trivy + Grype scan in the build script with CRITICAL gate
  - Cosign sign with local key (per Phase 6.7 pattern; carry-in if not yet signed)

Deploy:
  - apps/{APP}/k8s/ manifests:
    - ServiceAccount {APP}-server with SPIFFE ID spiffe://secforge.local/ns/app/sa/{APP}-server
    - Deployment (2 replicas, PSS-restricted, SPIFFE-CSI mount)
    - Service ClusterIP only
    - AuthorizationPolicy: only {APP}-bff SPIFFE ID may call {APP}-server
    - AuthorizationPolicy: only {APP}-server SPIFFE ID may call SpiceDB and Postgres
    - NetworkPolicy: default-deny + targeted allows
  - {APP}-bff Deployment built from apps/helloworld-bff/ source — copy, rename, configure with the {APP} Keycloak client ID and the {APP}-server upstream
  - Ingress: {APP_HOST} (pf.secforge.local for Proposal Forge, pt.secforge.local for Project Tracker)
  - mkcert cert via cert-manager
  - All images Cosign-signed; Kyverno verification in Audit (will flip to Enforce alongside the Phase 6.7 carry-in)

## Phase 10.{N}.7 — Observability wiring

  - Promtail scrape config picks up app logs by namespace label
  - Grafana dashboard for {APP}: request rate, error rate, p50/p95/p99 latency, AuthZEN deny rate, OpenBao secret-fetch rate
  - Wazuh rules for app-level events: auth failures, AuthZEN denies, unusual outbound-API-call patterns
  - OpenTelemetry tracing: BFF → server → SpiceDB → Postgres trace propagates end-to-end

## Phase 10.{N}.8 — End-to-end verification

For Project Tracker (single-user pilot):
  - Sign in as jason.upole via passkey at https://pt.secforge.local
  - Create a project, a pursuit, a task — verify they persist
  - Generate a Word/PDF/Excel report — verify it works
  - Trigger an MCP-server interaction — verify (per CLAUDE.md hard rule) it does NOT call api.anthropic.com from the backend

For Proposal Forge:
  - Sign in as jason.upole; verify display name comes from Keycloak, not the app's old User table
  - Create an organization, invite a second test user (alice.test from Keycloak) — verify SpiceDB grants alice the right role
  - Run an RFP through the wizard — verify Anthropic SDK calls work with the OpenBao-sourced API key
  - Export a .docx and .xlsx — verify they generate correctly
  - As alice, attempt to edit jason's proposal — verify 403 with AuthZEN deny in observability

## Phase 10.{N}.9 — Decommission the local docker-compose stack

Once the in-cluster app is verified for 1 week of normal use:
  - `docker compose down -v` in C:\Users\jaupo\Projects\{APP_DIR} (drops local Postgres + the now-stale local app data)
  - Update {APP}'s CLAUDE.md to point at the in-cluster URL instead of localhost:3001 / localhost:3002
  - Update {APP}'s package.json `dev` script to a thin wrapper that just opens the in-cluster URL (or, if you keep local dev, ensure it points at the cluster's BFF — no more local Postgres)
  - Archive (do not delete) the original docker-compose.yml in {APP_DIR}/docs/legacy/ for reference

## Phase 10.{N}.10 — Documentation

  - docs/01-architecture/apps/{APP}.md (created in 10.{N}.1, finalized here)
  - docs/03-runbooks/{APP}-operations.md (deploy, rollback, troubleshoot, backup, restore)
  - Update {APP}'s own CLAUDE.md: tech-stack section now reflects "auth via SecForge BFF, secrets via OpenBao, deployed in app namespace" — strip the Passport/JWT/cookie sections
  - Screenshots into docs/06-reference/screenshots/{APP}/

## Constraints

- Same as the platform: no tokens in browser, defense in depth, dynamic creds, SpiceDB checks every request
- App talks ONLY to its own backend; never directly to Keycloak/SpiceDB/OpenBao from the browser
- App's database tables in its own Postgres schema with RLS
- App's Wazuh rules tagged with app name for filtering
- {APP}'s pre-existing CLAUDE.md hard rules (Project Tracker: no Anthropic API calls in backend; Proposal Forge: AI-provider-agnostic) remain in force — platform integration does not weaken them
- No .env files in the integrated app — committed or otherwise
```

---

## Sequencing

| Step | Project Tracker | Proposal Forge |
|---|---|---|
| 10.1.1 — Audit | Week 1 | Week 3 (after PT cutover) |
| 10.1.2 — SpiceDB | Week 1 | Week 3 |
| 10.1.3 — Postgres migration | Week 1 | Week 3 |
| 10.1.4 — Strip local auth | Week 2 | Week 4 |
| 10.1.5 — OpenBao secrets | Week 2 | Week 4 |
| 10.1.6 — Containerize/deploy | Week 2 | Week 4 |
| 10.1.7-10 — Observability/verify/decom/docs | Week 2 | Week 5 |

Do not start Proposal Forge integration while Project Tracker is mid-cutover. The point of staggering is for Project Tracker's bumps to inform Proposal Forge's prompt.

---

## Success criteria

- [ ] Both apps reachable at `https://pt.secforge.local` and `https://pf.secforge.local`
- [ ] Both apps authenticate via Keycloak passkey (no local login form remains in either)
- [ ] Both apps' permission checks go through SpiceDB on every request
- [ ] Both apps' outbound API keys live in OpenBao only — no `.env` files committed or local
- [ ] Both apps' data resides in `secforge-app-db` with RLS enabled
- [ ] Both apps' images Cosign-signed and Kyverno-verified
- [ ] Both apps observable end-to-end in Grafana/Loki/Tempo/Wazuh
- [ ] Local docker-compose stacks decommissioned
- [ ] Project Tracker's "no Anthropic API calls in backend" rule still verified post-integration
- [ ] Proposal Forge's AI-provider-agnostic switching still works post-integration
- [ ] Architecture docs and runbooks committed for both apps
- [ ] PLAN.md updated

---

## Troubleshooting

### "BFF authenticates but the app rejects the forwarded headers"
Most common: header-name mismatch between what the BFF sends and what `apps/lib/api-auth/` expects. Both sides must agree on the canonical names (per docs/01-architecture/04-bff-pattern.md). Don't let each app invent its own.

### "Prisma migration fails because the User table has data"
Expected. The User table's auth fields (password_hash, refresh_token, etc.) are dropped; only `sub`, `email`, `display_name`, `created_at` survive, and `sub` is populated by joining the existing User table to Keycloak users via email match. Write the data-transformation SQL explicitly — don't let Prisma's migration runner make destructive guesses.

### "Anthropic SDK call fails after OpenBao migration"
Library cache miss → SPIFFE-JWT auth race → OpenBao 403. Check that the app's ServiceAccount has a `ClusterSPIFFEID` registered and the JWT auth role exists. Look in OpenBao audit log for the specific error.

### "Project Tracker MCP server stops working in-cluster"
Per its CLAUDE.md, the MCP server runs off Jason's Claude subscription, not an API key. The MCP transport assumes localhost; running it inside a pod requires either (a) re-architecting MCP for cluster-internal use, or (b) keeping the MCP server running on the host while the rest of Project Tracker is in-cluster. Decide before deploying — likely (b) for the local edition.

---

## What's next

[Phase 11 — Develop additional apps](./phase-11-develop-apps.md). The future PM app and any further products use the per-app checklist established by Phase 10.

When you have a real timeline pressure to launch, switch to a migration playbook in `docs/06-reference/`.
