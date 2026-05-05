# Hello World End-to-End Demo (Phase 9 — RETIRED 2026-05-04)

> **Status:** ✅ **Retired 2026-05-04** via `infrastructure/helloworld/teardown.sh` after the 9.10.5 checkpoint passed. The running demo no longer exists in the cluster. **This document remains as the historical reference for "this is how an app integrates with the platform"** and feeds Phase 10.
>
> **Source code preserved as the reference Phase 10 forks from:**
> - `apps/helloworld-frontend/` — minimal HTML+JS+CSS, served via nginx-unprivileged
> - `apps/helloworld-backend/` — Go API: JWT+DPoP via `apps/lib/api-auth`, SpiceDB CheckPermission via `apps/lib/authzn`, dynamic Postgres creds via `apps/lib/secrets`
> - `apps/helloworld-bff/` — Backend-for-Frontend: OIDC PAR+PKCE+DPoP, session in Valkey, OpenBao private_key_jwt, reverse-proxy with htu canonicalization
>
> **Reproducibility scripts** (Phase 10 may copy/adapt these):
> - `infrastructure/helloworld/create-users.sh` — TOTP-required users in `secforge-tenants`
> - `infrastructure/helloworld/provision-db-and-bao.sh` — DB schema + OpenBao role + JWT auth role
> - `infrastructure/helloworld/seed-spicedb-uuids.sh` — UUID-keyed access matrix tuples
> - `infrastructure/helloworld/register-helloworld-api-scope.sh` — Keycloak audience-mapper provisioning
> - `infrastructure/helloworld/teardown.sh` — idempotent reverse-of-deploy
> - `infrastructure/helloworld/verify-clean.sh` — 8-check residue validator
>
> **Why it's retired, not extended:** Phase 9 was disposable proof-of-platform; Phase 10 deploys real apps (Proposal Forge + Project Tracker) on the same infrastructure pattern. Keeping the running demo around would compete for the `helloworld-bff` Keycloak client name and `app.secforge.local` Ingress host with Phase 10's real apps.
>
> **Purpose:** disposable proof-of-platform — exercise every component end to end before Phase 10 wires up the real apps. Nothing here is permanent.

---

## What this demo proves

A real user, in a real browser, signs in with their factor and asks for a resource. The platform — every part of it — has to cooperate to answer that request:

- **Keycloak** authenticates the user (TOTP + recovery codes per [ADR-0007](../02-decisions/0007-totp-instead-of-passkeys-locally.md); not passkeys yet).
- **BFF** holds the OIDC tokens server-side, mints DPoP-bound bearers, and proxies the call.
- **SPIRE** issues SPIFFE IDs to BFF and backend; **Istio Ambient** + ztunnel give them mTLS.
- **OpenBao** issues the BFF its `private_key_jwt` and the backend its dynamic Postgres credentials.
- **`apps/lib/api-auth`** validates the inbound JWT + DPoP on the backend ([Phase 6b-1](../05-claude-code-prompts/phase-06b-api-pattern.md)).
- **SpiceDB** answers `can(user, permission, resource)` for every request.
- **Kyverno** refuses to admit any image that isn't Cosign-signed.
- **OTel → Tempo / Loki / Prometheus / Wazuh** all see the request with a correlated `trace_id`.

If a single one of those fails, the request fails. That's the point.

---

## Components

| Component | Path | Net-new vs reused |
|---|---|---|
| `helloworld-frontend` | `apps/helloworld-frontend/` (static HTML/JS/CSS) | **Net-new** in 9.5 |
| `helloworld-backend` | `apps/helloworld-backend/` (Go) | **Net-new** in 9.4 |
| `helloworld-bff` | `apps/helloworld-bff/` (Go, **already running** 1/1 from Phase 6) | **Extended** in 9.6: add static-asset serving + `/api/*` proxy via `apps/lib/api-auth.Client` |
| `apps/lib/api-auth` | `apps/lib/api-auth/` | Reused (Phase 6b-1 — Hello World is its first real consumer) |
| `apps/lib/secrets` | `apps/lib/secrets/` | Reused (Phase 6b-2) — BFF for `private_key_jwt`; backend for dynamic Postgres credentials |
| `secforge_app` DB schema `helloworld` | Postgres in `secforge-app-db-1` | **Net-new** in 9.4: `helloworld.documents` table seeded with one row; dropped at 9.12 |

The frontend is **served by the BFF as static files** (no separate frontend pod). The doc note: in cloud, you'd serve from a CDN; locally, the BFF doing it is the simplest correct thing.

---

## Permission model

One resource, three users, two permissions. Minimal but exercises every code path.

```
schema (already loaded, Phase 4):
  definition tenant   { relation admin: user … }
  definition app      { relation tenant: tenant; relation user: user … }
  definition document { relation app: app; relation owner: user; relation viewer: user
                         permission view = owner + viewer + app->user
                         permission edit = owner }
```

Relationships added in 9.3 (removed in 9.12):

| Subject | Relation | Object |
|---|---|---|
| `user:jason` | `admin` | `tenant:helloworld` |
| `tenant:helloworld` | `tenant` | `app:helloworld-app` |
| `user:alice` | `user` | `app:helloworld-app` |
| `app:helloworld-app` | `app` | `document:welcome` |
| `user:jason` | `owner` | `document:welcome` |
| `user:alice` | `viewer` | `document:welcome` |

Resulting access matrix (the demo's contract — verified in 9.3 with `zed permission check`):

| User | `view document:welcome` | `edit document:welcome` |
|---|---|---|
| `jason` | ALLOWED (owner) | ALLOWED (owner) |
| `alice` | ALLOWED (viewer) | DENIED |
| `bob` | DENIED | DENIED |

---

## Request flow

Concrete URLs and identities — this is what 9.10's negative tests check against.

```
Browser (TOTP-authenticated user)
   │  https://app.secforge.local/api/document/welcome
   ▼
BFF  helloworld-bff (Deployment in app namespace)
     SPIFFE ID: spiffe://secforge.local/ns/app/sa/helloworld-bff
     - validates session cookie (Valkey)
     - mints DPoP proof for THIS exact URL via apps/lib/api-auth.Client
     - attaches Authorization: DPoP <jwt>  +  DPoP: <proof>
   │  http://helloworld-backend.app.svc.cluster.local:8080/api/document/welcome
   ▼  (Istio Ambient mTLS, ztunnel-to-ztunnel)
helloworld-backend (Deployment, 2 replicas)
     SPIFFE ID: spiffe://secforge.local/ns/app/sa/helloworld-backend
     - apps/lib/api-auth.Middleware.ValidateInbound:
         · JWT signature against Keycloak JWKS
         · DPoP htm/htu/iat/jti/ath; htu canonicalized per dpop-htu-canonicalization.md
         · jti replay LRU (5-min TTL)
         · cnf.jkt thumbprint match
     - extracts subject claim → SpiceDB CheckPermission
   │  grpc spicedb.spicedb.svc.cluster.local:50051 CheckPermission(user, view, document:welcome)
   ▼
SpiceDB
     - returns ALLOWED / DENIED
   ▲
backend
     - if DENIED: 403 with {"error":"forbidden"} (no DB read)
     - if ALLOWED: SELECT content FROM helloworld.documents WHERE id=$1
                   using dynamic Postgres creds fetched via apps/lib/secrets
                   (creds rotate every 1h via OpenBao; backend re-fetches on auth fail)
     ▲
backend returns 200 with document JSON
   ▲
BFF returns the same status to the browser; never strips trace_id.
```

Every hop emits OTel spans with the same `trace_id`. Every hop logs structured JSON with that `trace_id`. Wazuh sees the Keycloak login event separately (audit trail entry-point).

---

## Identities & policies (deployed in 9.7)

- **ServiceAccounts** (`app` namespace): `helloworld-backend`. (`helloworld-bff` already exists from Phase 6.)
- **ClusterSPIFFEID**: namespace-scoped `app` registration already exists; backend SPIFFE ID derives from its SA.
- **Istio AuthorizationPolicy** (in `app`): `helloworld-backend` accepts traffic only from `spiffe://secforge.local/ns/app/sa/helloworld-bff`.
- **Istio AuthorizationPolicy** (in `spicedb`): SpiceDB accepts gRPC only from `helloworld-backend` (in addition to existing `authzen-facade` rule).
- **NetworkPolicy** on `helloworld-backend`: ingress from BFF's pod-selector only; egress to SpiceDB + Keycloak JWKS + OpenTelemetry collector + DNS.
- **OpenBao**:
  - JWT auth role `helloworld-bff` (already wired from Phase 6) ← BFF's `private_key_jwt` lives at `secret/data/keycloak/clients/helloworld-bff`.
  - JWT auth role `helloworld-backend` ← bound to SPIFFE ID `spiffe://secforge.local/ns/app/sa/helloworld-backend`. Policy grants `database/creds/helloworld-backend` (dynamic Postgres role) only. No KV access.
  - Postgres dynamic role `helloworld-backend` mints short-lived (1h) DB credentials with `USAGE` on schema `helloworld`, `SELECT` on `helloworld.documents`, `UPDATE` on `helloworld.documents`. Static Postgres user `helloworld_app_owner` owns the schema and is created at deploy time, not via OpenBao.
- **Postgres**:
  - Schema `helloworld` inside the existing `secforge_app` database (no new DB — cleaner teardown).
  - Table `helloworld.documents (id text primary key, owner text not null, content text not null, updated_at timestamptz not null default now())`.
  - Seed row: `('welcome', 'jason@example.com', '<lorem ipsum>', now())`.
  - Postgres RLS is **not** enabled on this table — single-tenant demo, the SpiceDB check is the only authorization gate. (Phase 10's real apps will have RLS per CLAUDE.md.)

---

## Observability hooks

Each request produces these signals — verified in 9.9:

| Signal | Backend | Where to look |
|---|---|---|
| Login event | Wazuh | `event.module: keycloak` filter on subject `jason@example.com` etc. |
| BFF + backend logs | Loki | `{app="helloworld-bff"} \|= "trace_id="` and same for `helloworld-backend` |
| Distributed trace | Tempo | search by `service.name=helloworld-bff` then drill into spans |
| Request rate / latency | Prometheus | `http_server_duration_seconds_*` filtered by `service="helloworld-backend"` |

---

## Key design decisions (Phase 9-specific)

1. **TOTP, not passkeys.** The Phase 9 prompt predates [ADR-0007](../02-decisions/0007-totp-instead-of-passkeys-locally.md). All three users enrol TOTP + recovery codes on first login. Passkey ceremony returns at production hardening (per ADR-0007 § Reversal triggers).
2. **Frontend served by BFF as static files.** Local convenience; cloud edition would use CDN. Documented in `apps/helloworld-frontend/README.md` and the Phase 10 hand-off so it doesn't get copied as a permanent pattern.
3. **Backend uses Postgres via OpenBao dynamic credentials.** The demo exercises the full secret-rotation path: `apps/lib/secrets` fetches creds, retries on `28P01` (password auth failure) by re-fetching from OpenBao, never holds creds longer than their lease. Tables live in a new `helloworld` schema inside the existing `secforge_app` DB so teardown is `DROP SCHEMA helloworld CASCADE` plus dropping the OpenBao roles — no DB cluster lifecycle.
4. **`htu` canonicalization is delegated, not re-derived.** `apps/lib/api-auth.Middleware.ValidateInbound` already implements [`docs/06-reference/dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md) — Phase 9 must NOT re-derive it. (Past phases hit subtle bugs around trailing slashes; this is the canonical fix.)
5. **No backend-side decision cache.** SpiceDB is asked on every request. Caching authorization decisions is a Phase 11 conversation, not a Phase 9 one — caching invariants depend on the application's invalidation strategy, which we don't have yet.
6. **Replay protection is in-memory LRU per backend pod.** Two replicas means a `jti` could in principle be replayed across pods, but DPoP `iat` skew (60s) bounds the window. For Phase 9 this is acceptable; cloud edition migrates to a Valkey-backed shared replay cache.

---

## Negative-path contracts (verified in 9.10)

| Scenario | Expected result | Observability evidence |
|---|---|---|
| Direct call to `helloworld-backend:8080` from another pod (no JWT) | 401 | Loki: `helloworld-backend` log `event=auth.reject reason=missing_authorization` |
| Valid JWT, no `DPoP` header | 401 | Loki: `event=auth.reject reason=missing_dpop` |
| `DPoP` proof for a different URL (`htu` mismatch) | 401 | Loki: `event=auth.reject reason=htu_mismatch` |
| Replayed `jti` within 5 min | 401 | Loki: `event=auth.reject reason=jti_replay` |
| Expired access token | BFF auto-refreshes and retries; user sees 200 | Loki: `helloworld-bff` log `event=token.refresh result=ok` |
| `bob` calls `/api/document/welcome` | 403 | Loki: backend `event=authz.deny`; SpiceDB: `permission.check` decision=DENY |

---

## What teardown removes vs preserves (Phase 9.12)

The teardown contract is in `phase-09-hello-world.md § 9.12`. Summary:

**Removed:** running `helloworld-backend` workloads + their AuthZ/Network policies; KC users `jason`/`alice`/`bob`/`test-bot`; KC client `helloworld-bff` (the *running* one — see preserved); SpiceDB relationships under `tenant:helloworld` and `document:welcome`; OpenBao paths `secret/data/apps/helloworld-*`, JWT auth role `helloworld-backend`, Postgres role `database/roles/helloworld-backend`, and any active dynamic-credential leases under it; Postgres schema `helloworld` (`DROP SCHEMA helloworld CASCADE`) plus the static role `helloworld_app_owner`; backend's container image; helloworld-specific ClusterSPIFFEIDs; the helloworld Ingress route.

**Preserved:** the platform itself; `apps/helloworld-frontend/`, `apps/helloworld-backend/`, `apps/helloworld-bff/` source trees as the reference implementation that Phase 10 forks; `apps/lib/api-auth/` and `apps/lib/secrets/` (these are platform libs, not demo code); the three skeleton BFF clients in Keycloak (`proposal-forge-bff`, `project-tracker-bff`, `pm-bff`); all Phase 1 databases; all screenshots and ADRs.

The teardown script `infrastructure/helloworld/teardown.sh` is **idempotent** — re-running it after partial failure must converge on the clean state, not error out.

---

## Cross-references

- Phase prompt: [`docs/05-claude-code-prompts/phase-09-hello-world.md`](../05-claude-code-prompts/phase-09-hello-world.md)
- Auth library: [`docs/01-architecture/06-api-pattern.md`](./06-api-pattern.md), [`docs/06-reference/dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md)
- BFF pattern: [`docs/01-architecture/04-bff-pattern.md`](./04-bff-pattern.md)
- SpiceDB schema + AuthZEN façade: [`docs/01-architecture/02-authorization.md`](./02-authorization.md)
- Workload identity: [`docs/01-architecture/06-workload-identity.md`](./06-workload-identity.md)
- ADR-0007 (TOTP): [`docs/02-decisions/0007-totp-instead-of-passkeys-locally.md`](../02-decisions/0007-totp-instead-of-passkeys-locally.md)
- ADR-0022 (kcadm-admin SA pattern): [`docs/02-decisions/0022-kcadm-admin-service-account.md`](../02-decisions/0022-kcadm-admin-service-account.md)
