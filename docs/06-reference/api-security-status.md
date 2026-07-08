# API Security Hardening Status

Tracks the security-hardening tier each API in the SecForge ecosystem has reached.
Update this file when promoting an API to a new tier or when adding a new API.

Tiers are defined in [§Tier definitions](#tier-definitions) below. The status snapshot is
the at-a-glance view; the per-API checklists are the detailed view.

---

## Status snapshot

| API | Codebase | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|---|
| `ecosystem-control` (control-plane API) | [Ecosystem Control/](../../../Ecosystem%20Control/) | ✅ 2026-05-09 | ⏳ partial (7/8) — see checklist | ⏸️ Phase 9 cutover | 🔁 ongoing |
| `managerapp` BFF (Project Tracker) | [Project Tracker/server/](../../../Project%20Tracker/server/) | — not built | — | — | — |
| `proposalapp` BFF (Proposal Forge) | [Proposal Forge/server/](../../../Proposal%20Forge/server/) | ⚠️ legacy auth, predates this matrix; full audit due at Phase 6 (PF migration) | — | — | — |
| _(future)_ `invoiceapp` BFF | — | — | — | — | — |
| _(future)_ `contactsapp` BFF | — | — | — | — | — |
| _(future)_ `pmapp` BFF | — | — | — | — | — |

**Legend:** ✅ done · ⏳ in progress · ⏸️ deferred to listed phase · 🔁 ongoing · ⚠️ needs audit · — not started

**Rule:** No API moves to its first real user without Tier 1 + Tier 2 ✅. No API moves to Hetzner without Tier 3 ✅. Tier 4 is permanently ongoing.

---

## Tier definitions

### Tier 1 — Baseline (must apply before any non-toy traffic)
Items every API gets on day one. Roughly 30–60 min of work per API.

1. JWT algorithm pinning (`RS256` only — never accept `alg: none` or HS variants on a public key)
2. Audience claim narrowed to legitimate clients only (no Keycloak `account` client, no wildcards)
3. Rate limiting (per-user when authenticated, per-IP otherwise; localhost allowlisted in dev only)
4. Security headers via `@fastify/helmet` (or framework equivalent): X-Content-Type-Options, X-Frame-Options, Referrer-Policy, HSTS
5. Custom error handler — no stack traces leaked to client; stable shape `{error, requestId}`; full detail logged server-side
6. Health/readiness endpoints don't leak internal state (no "db unreachable" details in 503 body)
7. Body size limit (default 256 KB) + connection/keep-alive timeouts
8. Log redaction for `authorization`, `cookie`, `*.password`, `*.secret`, `*.token`, `*.access_token`, `*.refresh_token`

### Tier 2 — Pre-customer (must complete before any external user touches the API)
Items that gate "OK to invite real users." Done alongside Phase 2–3 of the ecosystem rollout.

1. CSRF strategy decided + implemented for cookie-auth routes (bearer-only, double-submit, or `@fastify/csrf-protection`)
2. Zod input validation on every route via Fastify `schema` option (params, query, body)
3. Response serialization schemas (strip unknown fields; prevents accidental DB column leakage)
4. SpiceDB authorization check on every org-scoped endpoint — JWT validates *who*, SpiceDB validates *what they can do*
5. Postgres RLS on all org-scoped tables; auth middleware sets `SET LOCAL app.user_id` and `app.org_id` per transaction
6. Append-only audit log for state-changing operations (`actor_user_id, action, target_id, request_id, timestamp, before, after, ip`)
7. PII fields (invitation emails, contact data) encrypted via OpenBao Transit (per [encryption architecture memory](../../../Ecosystem%20Control/))
8. Token revocation/introspection check on sensitive operations (role grants, billing, workflow approvals)

### Tier 3 — Production cutover (Hetzner Phase 9)
Items that promote dev-quality config to production-quality config.

1. Secrets from OpenBao, not `.env` files
2. mTLS on SpiceDB connection (drop `INSECURE_LOCALHOST_ALLOWED`)
3. NetworkPolicy default-deny + explicit ingress/egress allowlist (per [egress filtering Layer A](../../../Ecosystem%20Control/))
4. Keycloak brute-force protection enabled in production realm only (NOT local dev — login friction; see `feedback_local_dev_no_mfa.md`)
5. Container hardening: distroless base, non-root UID, read-only rootfs, no shell
6. Postgres `statement_timeout` set per session (e.g., 5 s)

### Tier 4 — Ongoing (continuous, not a one-time checkbox)
1. `pnpm audit` in CI on every PR; fail build on `high` or `critical`
2. Dependency updates via Renovate/Dependabot (auto-merge patch, manual review minor)
3. SBOM generation at container build (`syft`)
4. Annual penetration test before any feature flagged "GA"

---

## Per-API checklists

### `ecosystem-control` — control-plane API

#### Tier 1 — ✅ complete (2026-05-09)
- [x] JWT alg pinning (`RS256`) — [src/api/middleware/auth.ts](../../../Ecosystem%20Control/src/api/middleware/auth.ts)
- [x] Audience checked against the trusted client set — `control-admin`, `control-portal`, and the ecosystem-app clients `member-hub` / `member-hub-system`. `account` is also accepted as a soft fallback (Keycloak includes it by default); the strict `azp` allowlist below is the real gate, so `account` in `aud` grants nothing on its own — see the comment in [auth.ts](../../../Ecosystem%20Control/src/api/middleware/auth.ts)
- [x] `azp` (authorized party) check against allowlist — defense-in-depth alongside `aud`
- [x] Audience self-mappers (`oidc-audience-mapper`) configured on the realm clients — without these the audience check 401s every token. Bootstrap covers the existing clients; each new ecosystem-app client needs one added
- [x] Rate limiting: 100/min global; per-user-sub when authenticated; 127.0.0.1 allowlisted in dev
- [x] `@fastify/helmet` registered with defaults (CSP off — JSON API; CORP `same-site`)
- [x] Custom error handler returning `{error, requestId}` with full detail logged via pino
- [x] `/readyz` returns `{status: 'not_ready'}` only on failure (no `reason` field)
- [x] `bodyLimit: 256 KB`; `connectionTimeout: 30 s`; `keepAliveTimeout: 5 s`
- [x] Pino redaction: authorization, cookie, set-cookie, password, secret, token, access_token, refresh_token

#### Tier 2 — ⏳ partial (7/8)
- [x] **CSRF strategy decided 2026-05-09**: bearer-required for all state-changing endpoints (Authorization header is not auto-sent cross-origin). The session cookie carries *context* (`active_org_id`) only — it grants nothing on its own. CSRF risk reduced to "an attacker page can read no portal state and trigger no state changes via cookie alone." Re-evaluated 2026-05-20: the QBO OAuth connect/callback is the one bearer-exempt path — a browser redirect flow, CSRF-protected by an OAuth `state` nonce + a short-lived state cookie (`nonceEquals` in `accounting-config.ts`) rather than a bearer.
- [x] **Zod input schemas** on every route via `fastify-type-provider-zod` — `params`, `body`, `response` (orgs routes; `/me` has no input)
- [x] **Response serialization schemas** — Zod schemas in `response: { 200: ... }` strip unknown fields automatically
- [x] **SpiceDB authz check** on org-scoped endpoints — `GET /api/v1/orgs/:id` checks `organization:<id>#view` before any DB read; `POST /api/v1/orgs/switch` does the same. Helper in [src/api/lib/spicedb-check.ts](../../../Ecosystem%20Control/src/api/lib/spicedb-check.ts) uses `fully_consistent` mode (never a stale "yes")
- [x] **Postgres RLS** on `ecosystem_control` DB tables — RLS enabled (migration `019_enable_rls`); org-scoped tables carry an `org_isolation` policy keyed on `app.org_id` (email-config `025`–`027`, `organization_accounting_config` `034`, `organization_stripe_config` `035`). The `withTx` helper ([src/api/db-tx.ts](../../../Ecosystem%20Control/src/api/db-tx.ts)) sets `app.user_id` + `app.org_id` per tx; the `/system/*` endpoints set `app.org_id` to the requested org to read cross-org under a service-account token.
- [x] **Audit log table** + write helper — migration 009; [src/api/lib/audit.ts](../../../Ecosystem%20Control/src/api/lib/audit.ts) writes inside the same transaction as the mutation (atomic). `audit_log` table has `REVOKE UPDATE, DELETE` for app role
- [x] **Audit row written** on `POST /api/v1/orgs/switch` (action `org.switch`, before/after `activeOrgId`)
- [x] **Transit encryption** for `pending_invitations` PII — migration `023_encrypt_invitation_pii` converted `invited_email` / `first_name` / `last_name` to OpenBao Transit ciphertext (`*_enc`); a parallel `invited_email_hmac` column preserves the dedupe lookup. Encrypt/decrypt via [src/api/lib/invitation-pii.ts](../../../Ecosystem%20Control/src/api/lib/invitation-pii.ts); the invitations routes apply it on every read/write. Vendor credentials (QBO/Stripe) follow the same pattern via `vendor-credentials.ts`.
- [ ] **Token introspection / revocation check** on sensitive operations — role-grant endpoints (`POST/DELETE /orgs/:id/members/:userId/roles`) and workflow approvals now exist; an introspection/revocation check on them is still unwired. **The one open Tier 2 item.**

#### Tier 3 — ⏸️ deferred to Phase 9 (Hetzner cutover)

#### Tier 4 — 🔁 ongoing (none of the four set up yet — first iteration: add `pnpm audit` to CI when CI exists)

### `managerapp` BFF
Not built. Tier 1 work happens at Phase 5 (managerapp integration) — apply this checklist before merging the BFF middleware PR.

### `proposalapp` BFF — ⚠️ legacy
Existing PF server has its own JWT auth from before this hardening matrix existed. Full audit + Tier 1 retrofit due at Phase 6 (PF migration to Keycloak). Do not assume any item is in place; verify each.

---

## Implementation log

Append a one-line entry per change. Newest at the top.

- **2026-07-08** — DB-unification canonical-core spine shipped (P1–P5; ADRs [0041](../02-decisions/0041-canonical-core-data-spine.md)/[0042](../02-decisions/0042-rls-guc-standard-app-org-id.md)/[0043](../02-decisions/0043-ecosystem-db-shared-package.md)/[0044](../02-decisions/0044-physical-db-consolidation.md)). **New Control system + org endpoints:** `GET /api/v1/system/core-export?entity=person|client|engagement&appId=…&cursor=…` (activation-scoped read stream, gated by `isSystemAzp` service-account tokens, `control_reader` read-only role, RLS `SET LOCAL app.org_id` per row); org-scoped `GET/POST people|clients|engagements` + merge + `GET /system/people/:id/email` (SpiceDB-gated, Transit-decrypt, audit-in-tx); system `resolve-kc`, roster create, engagement register/link, and handoff carry — all the **locked Tier 2 pattern** (Zod in/out, authz gate, RLS-aware `withTx`, atomic audit row). **Apps** (member-hub, proposal-forge, business-manager, project-manager) PULL those feeds with their existing system tokens over pinned egress (no new inbound surface, no Control egress client — the outbox/push was designed out); they hold READ-ONLY `core_people/core_clients/core_engagements` projections (FORCE-RLS, `app.org_id`). Cross-cutting: RLS session GUC unified fleet-wide on `app.org_id` (was app-specific names); the migration runner extracted to `@jaupole/ecosystem-db`; PF `users` table + EAV retired (attribution via `*_sub`), BM `users` retired; the 5 app databases consolidated onto one `ecosystem-db` CNPG cluster (connection secrets OpenBao-backed + VSO-rendered). Tracked in `db-unification/PROGRESS.md`.
- **2026-07-05** — PF Document Engine (DOCENG Phases 2–4 + M, deployed 2026-07-05). **New PF endpoints:** `GET /api/v1/onlyoffice/files/:token` (NO session — one-time single-use 256-bit token, 5-min TTL, delete-on-read in a tx, uniform 404, no-store+nosniff, per-IP limiter; never a fileKey in a URL) and `POST /api/v1/onlyoffice/callback/:projectId` (NO session — HS256 JWT verified from body token AND/OR `Authorization: Bearer` with `{payload}` wrapping, 403 unverified; document-key match with stale-key ack-and-ignore; SSRF host allowlist pinning the download `url` to `ONLYOFFICE_INTERNAL_URL`; 50 MB cap + zip sniff; RLS org context via the signed `?org=` param) — both mounted outside the session middleware ([server/routes/onlyoffice.routes.ts](../../../Proposal%20Forge/server/routes/onlyoffice.routes.ts)). Session-authed document routes `GET /api/v1/projects/:id/document`, `POST …/assemble` (409 `DOCUMENT_POLISHED` w/o confirm), `POST …/restore/:revision`, `GET …/download?format=docx|pdf`, `GET …/editor-config` (whole DocsAPI config JWT-signed; VIEWER/REVIEWER get edit:false) — proposal-scoped authz per PF conventions, expensive limiters on assemble/pdf. **New Control admin endpoints:** `GET /api/v1/admin/onlyoffice/usage` + `PATCH /api/v1/admin/onlyoffice/thresholds` ([src/api/routes/admin-onlyoffice.ts](../../../Ecosystem%20Control/src/api/routes/admin-onlyoffice.ts)) — platform-operator-only via `isPlatformAdmin` (SpiceDB `platform:ecosystem#administer`), strict Zod, audit row `platform.onlyoffice_thresholds.update` in-tx; read projection exposes no DS URL/secret; companion CronJob poller (`onlyoffice:poll-usage`) signs command-service calls (HS256, 5-min exp) and reaches the in-cluster DS only. **Removed PF endpoints (DOCENG-A9):** `/api/v1/me/oauth/*` (4) and `/api/v1/projects/:id/provider-doc/*` (4) — Google/M365 provider round-trip deleted; OAuth registrations + OpenBao values dormant (restore = git revert), env rendering removed from the pod. Platform: DS at `docs.secforge.dev` (public+tailnet, JWT-mandatory, zero-egress ns, /example denied at the VS, signed thin image `ghcr.io/jaupole/onlyoffice-documentserver`).
- **2026-06-07** — Member Hub document attachments for sponsors / prospects / events (deployed 2026-06-07, image `member-hub@cd29ee5c`). New: `GET/POST /api/v1/{sponsor,prospect,event}-documents/:entityId`, `GET /api/v1/{…}-documents/:entityId/:docId/download`, `DELETE /api/v1/{…}-documents/:entityId/:docId` ([entity-documents/routes.ts](../../../Member%20Hub/src/modules/entity-documents/routes.ts)) — mirror the existing `member-documents` shape. One generic Hono router factory mounted per entity, each behind `requireOrgPermission` with that entity's SpiceDB scope (sponsor + prospect = `administer`, event = `manage_members`); bearer/session via the member-hub `@jaupole/ecosystem-auth` BFF, so the locked CSRF strategy is unchanged. Metadata lives in the polymorphic `entity_documents` table (migration `097`, RLS `org_isolation` + `FORCE`), discriminated by `entity_type`; file bytes in MinIO (SSE-S3 at rest). Upload is multipart field `file` with a 10 MB cap + content-type allowlist; the object key is server-derived (`org/type/entity/doc` UUIDs), never the client filename; every download is served `Content-Disposition: attachment` so even an allowed type can't render inline / script. The parent is confirmed via an RLS-scoped existence check before any object write (no orphan object for a bad id); an audit row (`{entity}_document.upload` / `.delete`) is written in the mutation tx; `entity_id` is a logical reference (no FK), so each entity's delete path clears its document rows. The upload guards (size cap, allowlist, filename sanitiser, store resolver) are shared with `member-documents` via `lib/document-upload.ts` so the two can't drift.
- **2026-05-22** — Ecosystem-wide QuickBooks app config endpoint. New: `GET/PUT/DELETE /api/v1/admin/accounting/quickbooks-app` ([src/api/routes/ecosystem-accounting-config.ts](../../../Ecosystem%20Control/src/api/routes/ecosystem-accounting-config.ts)) — lets an ecosystem admin enter + rotate the single Intuit-registered QBO OAuth app's Client ID / Client Secret / redirect URI / environment from the Portal, instead of those being deploy-time-only `QBO_*` env vars. Gated to ecosystem (platform) admins via `isPlatformAdmin` (SpiceDB `platform:ecosystem#administer`) — the platform-admin equivalent of the per-org SpiceDB `check()`, since this config is platform-scoped not org-scoped. Follows the locked Tier 2 pattern otherwise: Zod `body`/`response` schemas (`.strict()` body), audit row (`platform.quickbooks_app.update` / `.cleared`) written in the mutation tx, bearer-required so the CSRF strategy is unchanged. The Client Secret is OpenBao Transit ciphertext (singleton table `ecosystem_quickbooks_app`, migration `041`) — same `*_enc` pattern as the per-org QBO/Stripe credentials — write-only on `PUT` and never echoed (`GET` returns a `clientSecretSet` boolean). Resolution precedence (`src/api/lib/qbo-app-config.ts`): a complete DB row wins; the `QBO_*` env vars remain a fallback so pre-existing deployments are untouched. RLS Tier 2 item is **not** contradicted — `ecosystem_quickbooks_app` is a global platform-scoped singleton (no `org_id`), like the `apps` catalog table, so org-isolation RLS does not apply; access control is the `isPlatformAdmin` gate and the secret column is ciphertext useless without the Transit key.
- **2026-05-20** — Accounting (QuickBooks) + Stripe per-org config endpoints (deployed 2026-05-20, image `control@dd7bf142`). New: `GET/DELETE /api/v1/orgs/:id/accounting-config`, `POST /api/v1/orgs/:id/accounting/qbo/connect` + the QBO OAuth callback; `GET/PATCH/DELETE /api/v1/orgs/:id/stripe-config`; and the service-account endpoints `GET /api/v1/system/orgs/:id/{accounting,stripe}-config`. Org-scoped endpoints follow the locked Tier 2 pattern — Zod `params`/`body`/`response` schemas, SpiceDB `check()` (`view` for reads, `administer` for mutations), RLS-aware `withTx`, audit row in the mutation tx. The `/system/*` endpoints are gated by `isSystemAzp` (the `member-hub-system` service-account client) instead of SpiceDB — a client-credentials caller has no SpiceDB org membership; they are confined to `/api/v1/system/*` and rejected by the org-scoped routes. All endpoints are bearer-required, so the locked CSRF strategy is unchanged. Outbound third-party credentials — QBO OAuth tokens, Stripe secret key + webhook signing secret — are stored as OpenBao Transit ciphertext (`*_enc` columns; `src/api/lib/vendor-credentials.ts`) and never echoed to a non-system caller (the org-scoped GET returns `*Set` booleans only). The QBO OAuth callback redirect is a fixed `PORTAL_ORIGIN`-derived URL (no open redirect). RLS Tier 2 item flipped to ✅ on the strength of these tables' `org_isolation` policies.
- **2026-05-09** — Members management endpoints (`GET /orgs/:id/members`, `PATCH /orgs/:id/members/:userId/status`, `POST/DELETE /orgs/:id/members/:userId/roles[/:roleId]`, `GET /orgs/:id/roles`). Each follows the locked Tier 2 pattern: Zod schemas in/out, SpiceDB CheckPermission gate (view for read, administer for mutate), 404-vs-403 distinction (don't leak existence to non-viewers), audit row in same tx as mutation, RLS-aware tx. Role assignment expands to SpiceDB via `syncOrgAdminRelation` helper — TOUCH/DELETE the org `administrator` tuple based on whether any of the user's role bundles include the org-level `administer` permission. Idempotent. App-level role expansion (per-org app instances) deferred to Phase 5. User display info resolved from Keycloak with 60s in-process LRU.
- **2026-05-09** — Active org context propagation: `@fastify/secure-session` registered; `POST /orgs/switch` sets `ecosystem_session.active_org_id`; auth middleware reads cookie (cookie wins over JWT claim); SpiceDB still gates every org-scoped endpoint so the cookie is a hint not a grant. `SESSION_KEY` env var (32 bytes base64); dev key in `.env`, prod from OpenBao. Vite proxy in portal routes `/api/*` → API for same-origin cookies. CSRF strategy locked: bearer-required + cookie-as-context-only. Portal `OrgSwitcher` component built but only one membership in dev so renders as "Working in Demo Co" label.
- **2026-05-09** — Test loop closed. `dev:seed-test-user` CLI seeds Keycloak user + DB membership + SpiceDB relationships idempotently; `dev:get-token` mints a token via password grant on `ecosystem-portal` (direct-grants flipped on locally for this — bootstrap script updated). Verified end-to-end with `alice` admin of `Demo Co`: `/me` returns membership; `GET /orgs/<id>` returns full payload (members + 8 roles) — proves SpiceDB authz check fires; `POST /orgs/switch` returns 200 + writes audit_log row with before/after `activeOrgId`. **Note:** the switch endpoint validates + audits intent only — propagating `active_org_id` into subsequent tokens is deferred to Phase 2 portal work (cleanest mechanism — cookie + custom claim vs. Keycloak user attribute + protocol mapper vs. token exchange — gets decided alongside OIDC flow).
- **2026-05-09** — `ecosystem-control` Tier 2 partial (5/8). Added `GET /api/v1/orgs/:id` and `POST /api/v1/orgs/switch` with: Zod input + response schemas via `fastify-type-provider-zod` (Zod upgraded 3→4); SpiceDB `CheckPermission` authz before any DB read (`fully_consistent` mode); RLS-aware transaction helper (`SET LOCAL app.user_id`/`app.org_id` per tx); audit_log table (migration 009) with append-only enforcement; audit row written atomically with mutations. Also added: `azp` allowlist check, audience self-mappers in Keycloak (one-time fix; bootstrap-realm.sh updated for fresh installs), validation error handler returning `{error: 'invalid_request', details, requestId}`.
- **2026-05-09** — `ecosystem-control` Tier 1 applied. JWT alg pinned `RS256`; audience tightened to `ecosystem-control` + `ecosystem-portal`; `@fastify/rate-limit` (100/min global, dev allowlist `127.0.0.1`); `@fastify/helmet` defaults; custom error handler with requestId; `/readyz` reason removed; `bodyLimit=256 KB`, `connectionTimeout=30 s`, `keepAliveTimeout=5 s`; pino redaction for auth/secret/token paths.
- **2026-05-09** — `ecosystem-control` initial Phase 1 skeleton: Fastify + JWKS auth + `/healthz` + `/readyz` + `/api/v1/me`. Tier-tracking matrix created.
