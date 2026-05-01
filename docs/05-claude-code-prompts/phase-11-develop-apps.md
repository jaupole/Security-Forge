# Phase 11 — Develop Additional Apps

**Status:** ⬜ Not started · ⬜ In progress · ⬜ Ongoing

**Estimated time:** Open-ended

**Prerequisites:** Phases 1-10 complete (or 1-7 + 9 + 10 if you skipped Teleport).

---

## Goal of this phase

Phase 10 brought Proposal Forge and Project Tracker into the ecosystem. Phase 11 is the generic "build a new app on this platform" checklist — used for the future PM app and any further products.

Each new app follows the same pattern Hello World demonstrated and Phase 10 productionized: Keycloak client + BFF + backend + SpiceDB schema additions + dashboards + CI/CD.

This isn't really a "phase" so much as the start of normal development. The structure here is a checklist you walk for each new app.

---

## What you (the human) need to do first

1. Decide whether the new app uses an existing skeleton client (`pm-bff`) or needs a brand-new one provisioned.
2. Sketch the rough domain model: what objects exist, who can do what to them, what's the multi-tenancy boundary.
3. Sketch the rough UI: what screens, what interactions, what data flows.
4. Read the Phase 10 integration prompt and `docs/01-architecture/apps/proposal-forge.md` + `project-tracker.md` to see how the first two real apps were structured — copy that pattern unless you have a strong reason to deviate.

---

## Keycloak clients required (verify or create per app)

Each app's BFF needs an OIDC client in Keycloak. **Phase 3.5 pre-created skeleton clients** for the four anticipated apps (`helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`); verify the one for the app you're working on still exists with the right config before Step 4 of the per-app checklist.

| App | Client ID | Realm | Redirect URI |
|---|---|---|---|
| Hello World | `helloworld-bff` | `secforge-tenants` | `https://app.secforge.local/auth/callback` |
| Proposal Forge | `proposal-forge-bff` | `secforge-tenants` | `https://pf.secforge.local/auth/callback` |
| Project Tracker | `project-tracker-bff` | `secforge-tenants` | `https://pt.secforge.local/auth/callback` |
| Future PM app | `pm-bff` | `secforge-tenants` | `https://pm.secforge.local/auth/callback` |

If the redirect URI changed since Phase 3.5 (different hostname, additional callback path), update via `infrastructure/keycloak/realms/bootstrap-bff-clients.sh` (idempotent) before running the per-app checklist. The Claude Code prompt won't catch a stale URI mismatch — Keycloak will reject the redirect and the BFF will fail with `invalid_request: redirect_uri does not match`.

**For brand-new apps not in the skeleton list:** add a new entry to `infrastructure/keycloak/clients/<new-app>.sh` (template from `openbao.sh`) so the client is reproducible on a fresh-cluster bootstrap. Don't click-through-create-only; that's the lesson from Phase 5 — every OIDC integration needs a script-based provisioner committed to the repo.

---

## Per-app checklist (use this as a Claude Code prompt template)

> Replace `{APP_NAME}`, `{APP_HOST}`, `{APP_DESC}` and copy into Claude Code per app.

---

```
We're starting work on {APP_NAME} on the SecForge Local Edition platform. Read CLAUDE.md, PLAN.md, docs/01-architecture/00-overview.md, docs/01-architecture/10-helloworld-demo.md (retired demo, kept as reference pattern), docs/01-architecture/apps/proposal-forge.md, docs/01-architecture/apps/project-tracker.md, and docs/05-claude-code-prompts/phase-11-develop-apps.md before doing anything.

{APP_DESC} — short description of the app and its purpose.

Walk this checklist with me, sub-step by sub-step, asking before each change.

## Step 1: Domain modeling
- What objects exist in {APP_NAME}? (Sketch them — use ER diagram or simple text.)
- For each object, what permissions are meaningful? (`view`, `edit`, `delete`, `share`, etc.)
- How do permissions flow? (Owner → editor → viewer? Org admin → all members?)
- What's the multi-tenancy boundary? (Per-tenant data isolation, per-org permission inheritance, etc.)

Document in docs/01-architecture/apps/{APP_NAME}.md.

## Step 2: Database design
- Postgres schema in `secforge-app-db` (one schema per app, e.g., `proposal_forge`)
- Multi-tenant tables include tenant_id with RLS policy
- Migrations checked in to apps/{APP_NAME}/migrations/

## Step 3: SpiceDB schema additions
- Add definitions to infrastructure/spicedb/schema.zed for {APP_NAME}'s objects
- Add validator tests
- Apply schema migration

## Step 4: Keycloak client
- Verify the {APP_NAME}-bff client created in Phase 3 has correct redirect URIs for {APP_HOST}.
  - Use `bash infrastructure/keycloak/verify.sh` (with KCADM_USER + KCADM_PASSWORD + KCADM_TOTP) for the full client check.
  - If the client doesn't exist (new app added after Phase 3), provision via `infrastructure/keycloak/clients/<APP_NAME>.sh` (clone the openbao.sh template). Lesson from Phase 5: every OIDC integration needs a committed kcadm provisioner script — UI-only setup makes fresh-cluster bootstraps painful.
- If new app not in Phase 3 list, add it now

## Step 5: BFF instance
Two options:
- Option A: dedicated BFF per app — copy apps/helloworld-bff to apps/{APP_NAME}-bff, configure, deploy as separate Deployment
- Option B: shared BFF with virtual host routing on host header — more efficient locally, more complex

Recommendation locally: Option A (dedicated). Cleaner separation; easier to reason about.

## Step 6: Backend service
- apps/{APP_NAME}-backend/ — Go service following the helloworld-backend pattern
- JWT + DPoP validation middleware (extracted to a shared library: apps/internal/auth/)
- SpiceDB client
- Postgres client (fetches credentials from OpenBao via SPIFFE auth)
- OpenTelemetry instrumentation
- Structured JSON logs

## Step 7: Frontend
- apps/{APP_NAME}-frontend/ — React or vanilla, your choice
- Calls only the BFF
- No tokens or sensitive data in browser storage
- Strict CSP

## Step 8: Deploy
- ServiceAccount + SPIFFE ID for backend and BFF
- AuthorizationPolicy: BFF → backend, backend → SpiceDB, backend → Postgres (via OpenBao)
- Ingress at {APP_HOST}
- Cosign-signed images, Kyverno-verified

## Step 9: Observability
- Add Grafana dashboard for {APP_NAME}
- Add Wazuh rules for app-specific events
- Verify trace propagates BFF → backend → SpiceDB

## Step 10: Tests
- Unit tests in each component
- Integration tests against the local cluster (testcontainers OK for unit tests, real cluster for integration)
- E2E tests using a headless browser (Playwright) running through the full passkey-or-bypass flow (use a TOTP test user for automation)

## Step 11: Documentation
- README in apps/{APP_NAME}/
- Architecture doc in docs/01-architecture/apps/{APP_NAME}.md
- Operational runbook in docs/03-runbooks/{APP_NAME}-operations.md

## Constraints
- Same as the platform: no tokens in browser, defense in depth, dynamic creds, SpiceDB checks every request
- App talks ONLY to its own backend; never directly to Keycloak/SpiceDB/OpenBao
- App's database tables in its own Postgres schema
- App's Wazuh rules tagged with app name for filtering
```

---

## When you have your full app portfolio running

You've completed the "build the platform locally and develop the apps against it" arc. At this point:

### Decision points

1. **Stay local indefinitely?** Some teams genuinely run their development this way long-term. Fine, as long as you understand the gaps (no real backups, no HA, no public access).

2. **Move to a single VPS / homelab?** Much closer to production but still self-hosted. Sustained ~$50-100/month for a beefy server. See `docs/06-reference/migration-to-vps.md` for the playbook.

3. **Move to AWS / GCP / Azure?** Full cloud deployment. ~$700-1500/month baseline. See `docs/06-reference/migration-to-aws.md` for the playbook (the AWS-Edition phase docs become applicable).

### Pre-migration hardening checklist

Regardless of destination, before exposing anything publicly:

- [ ] Walk the hardening checklist (the HTML planning workspace from your initial planning session, if you saved it)
- [ ] Run `kube-bench` against the cluster
- [ ] Run `kube-hunter` for known K8s vulnerabilities
- [ ] Run a Trivy image scan on every deployed image, fix all criticals
- [ ] Run OWASP ZAP against your apps
- [ ] Have someone other than you (or Claude) review your SpiceDB schema
- [ ] Test backup restoration end-to-end
- [ ] Test certificate rotation under load
- [ ] Test OpenBao seal/unseal procedures
- [ ] Document incident response procedures
- [ ] Set up status page

This is genuinely several weeks of work. Don't skip it.

### Documenting the migration

When you start a migration, create a new branch and a docs/migrations/<date>-<destination>.md tracking what changes. The local edition continues to exist (for development) while the new edition (for the destination) gets stood up in parallel. They share the application code but diverge in infrastructure.

---

## A note on app development pace

The platform took 3-5 weeks. The first app likely takes 2-4 weeks (most of that is your own product design, not platform plumbing). The second app should be much faster (2 weeks?) because the patterns are now established. The third faster still (1-2 weeks?).

If you're moving slower than this, the friction is usually not in the platform but in product decisions. That's normal — you can't rush "what should this thing do."

---

## What's next

This is the open-ended phase. There is no "Phase 12."

When you have a real timeline pressure to launch — when you have a customer, a deadline, or a release date — that's when you start thinking about migration. Until then, develop locally.

If you decide to migrate, fork the relevant playbook in `docs/06-reference/` and start a new build alongside this one.
