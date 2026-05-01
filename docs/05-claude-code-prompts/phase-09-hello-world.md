# Phase 9 — Hello World End-to-End Demo

> **Navigation:** ⬅ [Previous: Phase 8 — Teleport (optional)](./phase-08-teleport.md) · [Next: Phase 10 — Integrate Proposal Forge + Project Tracker](./phase-10-integrate-proposal-forge-project-tracker.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must ALL be ✅):** Phase 7 · Phase 6b-1 (api-auth library — Phase 9 is its first real consumer) · Phase 3 follow-up (kcadm-admin service-account pattern — Phase 9's user provisioning depends on it) · Fix-after-07 (closes audit findings that block Phase 9's design assumptions)
> **Blocks:** Phase 10 · Phase 11
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ Not started. **Hard-blocked on:** 6b-1, 3 follow-up, Fix-after-07. Phase 9 is **disposable proof-of-platform**, not a tenant — Phase 9.12 explicitly tears down the Hello World workloads/users/relationships/secrets after the 9.10.5 checkpoint.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2-3 days

**Prerequisites:** Phases 1-7 complete (Phase 8 optional).

---

## Goal of this phase

Build the smallest possible app that exercises every platform component end to end: passkey login → BFF session → DPoP-bound JWT to backend → backend validates → backend asks SpiceDB → backend returns data → all of it visible in observability. This proves the platform is working before you start on the real apps.

---

## What you (the human) need to do first

1. Confirm Phases 1-7 are complete.
2. Have at least 3 hardware passkeys ready (or use software passkeys). We'll create three test users: `jason` (owner), `alice` (viewer), `bob` (no access).

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 9 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-09-hello-world.md before doing anything.

Your task is to build a minimal Hello World demo that exercises every platform component end to end and proves the platform works.

## Phase 9.1 — Design

Document in docs/01-architecture/10-helloworld-demo.md:

The demo:
- Frontend (`apps/helloworld-frontend/`): static HTML + minimal JS, served by BFF
- Backend (`apps/helloworld-backend/`): Go service, validates JWT + DPoP, asks SpiceDB, returns data
- Permission model: a single resource `document:welcome` with three users:
  - `jason` (owner) — can view + edit
  - `alice` (viewer) — can view, not edit
  - `bob` (no access) — cannot view

The flow:
1. User browses to https://app.secforge.local
2. Frontend loads; checks /api/me to detect session
3. If no session → redirect to /login → BFF starts OIDC flow → Keycloak passkey → callback → session created
4. With session: frontend calls /api/document/welcome
5. BFF receives, mints DPoP proof, calls backend
6. Backend validates JWT signature, validates DPoP binding, asks SpiceDB if user can `view` document:welcome
7. If allowed: backend returns document content
8. If denied: backend returns 403; frontend shows friendly error
9. Frontend also calls /api/document/welcome/edit if user clicks edit; backend re-checks for `edit` permission

## Phase 9.2 — Set up Keycloak users

In `secforge-tenants` realm, create three users:
- jason@example.com — display name "Jason"
- alice@example.com — display name "Alice"
- bob@example.com — display name "Bob"

Force passkey registration on first login for each. (For automated testing, create a fourth user `test-bot` with TOTP enabled.)

## Phase 9.3 — Set up SpiceDB relationships

Schema is already loaded (Phase 4). Add the relationships:
```
zed relationship create tenant:helloworld#admin user:jason
zed relationship create app:helloworld-app#tenant tenant:helloworld
zed relationship create app:helloworld-app#user user:alice
zed relationship create document:welcome#app app:helloworld-app
zed relationship create document:welcome#owner user:jason
zed relationship create document:welcome#viewer user:alice
```

(Bob has no relationships → access denied for him.)

Verify:
```
zed permission check document:welcome view user:jason  → ALLOWED
zed permission check document:welcome view user:alice  → ALLOWED
zed permission check document:welcome view user:bob    → DENIED
zed permission check document:welcome edit user:jason  → ALLOWED
zed permission check document:welcome edit user:alice  → DENIED
```

## Phase 9.4 — Implement the backend

`apps/helloworld-backend/main.go`:
- HTTP server on :8080 (cluster-internal only)
- Endpoints:
  - GET /api/me → return user info from validated JWT
  - GET /api/document/:id → check `view`, return content
  - POST /api/document/:id → check `edit`, "save" (just echo for the demo)
- Middleware:
  - JWT validation (verify signature against Keycloak JWKS)
  - DPoP validation (verify thumbprint matches `cnf.jkt` claim, check `htm`/`htu`/`iat`/`jti`/`ath`). **`htu` MUST follow the canonical rule in [`docs/06-reference/dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md)** — the backend's `apps/lib/api-auth.Middleware.ValidateInbound` (Phase 6b-1) implements it; do NOT re-derive in this phase.
  - Replay cache for DPoP `jti` (in-memory LRU, 5-minute TTL)
- Calls SpiceDB via gRPC for permission checks
- Structured JSON logging with correlation to trace_id
- OpenTelemetry instrumentation

Distroless container, signed with Cosign (local key from Phase 1).

## Phase 9.5 — Implement the frontend

`apps/helloworld-frontend/`:
- `index.html` — minimal page
- `app.js` — vanilla JS (no framework needed for the demo); fetches /api/me on load, displays user, fetches document, shows content with View/Edit buttons
- `style.css` — minimal styling

NO authentication code in JS. NO token storage in JS. The frontend only reads the user's display name from /api/me, not any tokens.

The BFF serves these static files directly (no separate frontend server needed locally; document this is a local convenience and in cloud you'd serve from CDN).

## Phase 9.6 — Wire up the BFF

The BFF from Phase 6 needs:
- Static file serving from `/var/www/helloworld/` (mount the frontend assets in the BFF deployment)
- Proxy `/api/*` to `helloworld-backend.app.svc.cluster.local:8080`
- Inject DPoP-bound JWT on every backend call

Update the BFF deployment manifest from Phase 6 to include the static assets and the backend service URL.

## Phase 9.7 — Deploy

- Backend: 2 replicas in `app` namespace, ServiceAccount `helloworld-backend`, SPIFFE ID `spiffe://secforge.local/ns/app/sa/helloworld-backend`
- AuthorizationPolicy: only `helloworld-bff` SPIFFE ID can call backend
- AuthorizationPolicy: only `helloworld-backend` can call SpiceDB
- Frontend assets baked into BFF image (or in a shared volume)
- Update BFF Ingress to serve at `https://app.secforge.local`

Both backend and BFF images signed with Cosign and verified by Kyverno.

## Phase 9.8 — Test the flow

For each test user:

### As jason
1. Visit https://app.secforge.local — redirected to login
2. Authenticate with passkey
3. See "Hello, Jason" + the document content
4. Click "Edit" → success (returns 200)

### As alice
1. (Logout first) Visit https://app.secforge.local — log in as alice
2. See "Hello, Alice" + the document content
3. Click "Edit" → 403 with friendly error

### As bob
1. Log in as bob
2. /api/me succeeds (he's authenticated)
3. /api/document/welcome → 403 (he has no access to this document)
4. Frontend shows "You don't have access to this document"

## Phase 9.9 — Verify in observability

For each of the three flows above:
- Wazuh: see the Keycloak login event
- Loki: see structured logs from BFF + backend with correlated trace_id
- Tempo: see the trace BFF → backend → SpiceDB
- Prometheus: see the request count + latency histogram

If all three users' flows are visible end-to-end in observability, the platform is operational.

## Phase 9.10 — Negative tests

Verify these all fail correctly:
- Direct call to backend bypassing BFF (no JWT) → 401
- Call with valid JWT but no DPoP proof → 401
- Call with DPoP proof for a different URL (`htu` mismatch) → 401
- Call with replayed DPoP proof (same `jti`) → 401
- Call with expired JWT → 401, BFF should refresh automatically and retry
- Call as bob to a forbidden resource → 403 (and SpiceDB log shows the denial)

Each negative test should produce an observability event you can find.

## Phase 9.10.5 — Checkpoint (HUMAN SIGN-OFF REQUIRED — DO NOT PROCEED PAST THIS WITHOUT IT)

Hello World is a **disposable proof-of-platform**, not a permanent tenant. Phase 9.12 will tear it all down. Before that happens, the human must explicitly verify that every platform component is working as expected — because once teardown runs, this end-to-end evidence is gone.

**Stop. Do not proceed to 9.11 until the human has signed off.**

The human's checklist (they tick each box in PLAN.md before saying "go"):

- [ ] All three users (jason / alice / bob) authenticated via passkey at least once
- [ ] All positive flows from 9.8 produced the expected outcome
- [ ] All negative flows from 9.10 returned the expected error
- [ ] Wazuh, Loki, Tempo, and Prometheus each show data for at least one Hello World request
- [ ] No unexpected error events in the last 24h of platform logs
- [ ] Screenshots captured (these survive teardown — the running app does not)

When the human says "checkpoint passed, proceed to 9.11," continue. If anything fails, fix it before the checkpoint — do not paper over by tearing down a broken state.

## Phase 9.11 — Documentation

Update:
- docs/01-architecture/10-helloworld-demo.md — mark this as a *retired demo* once 9.12 runs; the doc becomes the historical reference for "this is how an app integrates with the platform" and feeds Phase 10
- README.md at the repo root: add a "Try it" section (note: only valid until 9.12 teardown — adjust wording so future readers know the demo is not running)
- Take screenshots and add to docs/06-reference/screenshots/ — these are the permanent evidence; capture before 9.12

## Phase 9.12 — Tear down Hello World

Hello World existed to prove the platform works. The checkpoint passed; it has done its job. Now remove it so the cluster is clean before Phase 10 deploys the real apps.

**What is removed:**

1. **Workloads** in `app` namespace:
   - `helloworld-backend` Deployment, Service, ServiceAccount
   - `helloworld-bff` Deployment, Service, ServiceAccount (the *running* BFF instance — the source code under `apps/helloworld-bff/` stays as the reference implementation Phase 10 copies from)
   - Any ConfigMaps / Secrets specific to Hello World
   - AuthorizationPolicies scoped to Hello World identities
   - NetworkPolicies scoped to Hello World identities
   - The `app.secforge.local` Ingress route serving the Hello World frontend

2. **Keycloak** (in `secforge-tenants` realm):
   - Delete the `helloworld-bff` client (skeleton from Phase 3 + any per-app config added in Phase 9)
   - Delete users `jason` (the test persona, not `jason.upole` admin), `alice`, `bob`, `test-bot`
   - **Do NOT delete** the `proposal-forge-bff` / `project-tracker-bff` / `pm-bff` skeleton clients — Phase 10 needs them

3. **SpiceDB** (in `secforge-tenants` schema namespace):
   - Delete relationships: `tenant:helloworld#admin`, `app:helloworld-app#tenant`, `app:helloworld-app#user`, `document:welcome#*`
   - Leave the schema itself unchanged — `tenant`/`app`/`document` types are reused by Phase 10

4. **OpenBao**:
   - Delete `secret/data/apps/helloworld-*` paths
   - Delete the `helloworld-bff` JWT auth role
   - Delete any Postgres dynamic-credential role prefixed `helloworld-`

5. **ClusterSPIFFEID registrations**:
   - Remove any `ClusterSPIFFEID` specific to Hello World workloads (the namespace-scoped `app` registration stays — Phase 10 workloads use it)

6. **Container images**:
   - `docker rmi` the `helloworld-frontend` and `helloworld-backend` local images (the BFF image stays because the *codebase* is the reference; Phase 10 will rebuild and re-tag it as `proposal-forge-bff` and `project-tracker-bff`)

**What is preserved:**
- The platform itself: Keycloak, SpiceDB, OpenBao, SPIRE, Istio, observability stack
- The reference source code under `apps/helloworld-frontend/`, `apps/helloworld-backend/`, `apps/helloworld-bff/` — Phase 10 copies from these
- `apps/lib/api-auth/` and `apps/lib/secrets/` (Phase 6b libraries — not Hello World)
- The three remaining skeleton BFF clients in Keycloak
- All architecture docs and ADRs
- All screenshots and runbooks
- The four Phase 1 Postgres databases (Hello World did not get its own DB)

**Implementation:** write `infrastructure/helloworld/teardown.sh` — idempotent, safe to re-run, prints what it deleted at the end. Commit this script alongside the Phase 9 deploy scripts so the teardown is reproducible and reviewable.

## Phase 9.13 — Verify the cluster is clean

After teardown, confirm Hello World left no residue:

- `kubectl get all -n app -l app.kubernetes.io/part-of=helloworld` returns nothing
- `kcadm get clients -r secforge-tenants --query clientId=helloworld-bff` returns empty
- `kcadm get users -r secforge-tenants -q username=alice` returns empty (and same for jason/bob/test-bot)
- `zed relationship read tenant:helloworld` returns no relationships
- `bao kv list secret/data/apps/` does not list `helloworld-*`
- `bao list auth/jwt/role` does not list `helloworld-bff`
- The platform itself is still healthy: BFF reference image is still in registry, Keycloak/SpiceDB/OpenBao all green, observability still ingesting platform logs
- A 5-minute soak: no errors in Loki related to dangling Hello World references

If anything residual is found, the teardown script gets a fix and re-runs. Phase 10 does not start until 9.13 is clean.

## Constraints

- No tokens in browser
- Backend trusts only signed images (Kyverno enforces)
- Backend authorizes via SpiceDB on every request — never caches decisions
- DPoP replay protection works (LRU cache with TTL)
- Every request has a trace_id propagated through the chain
- Errors return user-friendly messages, never leak internals
```

---

## Success criteria

- [ ] Three test users in Keycloak with passkeys
- [ ] SpiceDB relationships correct
- [ ] Backend validates JWT + DPoP, calls SpiceDB
- [ ] BFF serves frontend + proxies API
- [ ] Jason: full access; Alice: read-only; Bob: no access — all observed correctly
- [ ] All flows visible in Wazuh + Loki + Tempo + Prometheus
- [ ] Negative tests fail correctly
- [ ] Screenshots and docs in repo
- [ ] **9.10.5 checkpoint signed off by the human**
- [ ] **9.12 teardown executed; `teardown.sh` committed**
- [ ] **9.13 verification clean: no Hello World workloads, users, relationships, clients, secrets, or roles remain**
- [ ] PLAN.md updated

---

## Troubleshooting

### "DPoP validation fails"
Most common: trailing slash on URL. The BFF must use the exact URL the backend expects, character-for-character.

### "Backend can't reach SpiceDB"
AuthorizationPolicy. SpiceDB is in `spicedb` namespace; backend is in `app`. The policy must allow cross-namespace traffic from this specific SPIFFE ID.

### "JWT signature invalid"
Keycloak realm signing key changed (rotation, restart). Backend caches JWKS — invalidate (restart) or set shorter cache TTL.

### "Frontend shows 'session expired' after a few minutes"
BFF refresh token logic isn't working. Check BFF logs near the expiry — should see automatic refresh.

---

## What's next

[Phase 10 — Integrate Proposal Forge and Project Tracker](./phase-10-integrate-proposal-forge-project-tracker.md). With Hello World torn down, the cluster is clean and ready for the two real applications living in `C:\Users\jaupo\Projects\Proposal Forge` and `C:\Users\jaupo\Projects\Project Tracker`.

(Phase 11, the open-ended "build new apps" phase, picks up after Phase 10.)

🎉 **Celebrate.** You just stood up an auth platform that very few teams ever build correctly — and proved it works before letting any real app touch it.
