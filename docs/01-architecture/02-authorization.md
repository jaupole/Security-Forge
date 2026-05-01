# Authorization (SpiceDB) — Local Edition

> Companion ADRs:
> - [ADR-0008 — Authorization schema (three-tier)](../02-decisions/0008-authz-schema.md)
> - [ADR-0001 — Local-first build](../02-decisions/0001-local-first.md)
>
> Runbook: [spicedb-operations.md](../03-runbooks/spicedb-operations.md).
> Schema source-of-truth: [`infrastructure/spicedb/schema.zed`](../../infrastructure/spicedb/schema.zed).
> Companion architecture: [01-iam-platform.md](./01-iam-platform.md) (Keycloak issues the JWT; SpiceDB answers "is this user allowed to do this on this resource?").

This document describes how the platform separates **authorization** ("who can do what to what") from **authentication** ("who is this user"). Authentication is Keycloak's job; authorization is SpiceDB's. The two never collapse: a valid JWT means the request is from a known user; a CheckPermission `ALLOWED` means that user is permitted on a specific resource. Both are required on every sensitive endpoint.

---

## Goals

1. **All authorization decisions are externalized** from application code into a single policy engine. App code asks "can user X do action Y on resource Z?" and gets a yes/no — never expresses or stores ACL logic itself.
2. **The policy engine is fast.** P99 CheckPermission < 10ms in steady state; cache-warm decisions sub-millisecond. Apps will call CheckPermission on every authenticated request, so the budget is tight.
3. **Permissions are computable, not stored.** Whether `user:alice` can `view document:welcome` is a *graph traversal* over `{document:welcome → app:helloworld-app → tenant:helloworld → member}` relationships — not a row in an ACL table. New permission rules are schema changes, not migrations of millions of rows.
4. **The same model works for every app.** Hello World, Proposal Forge, Project Tracker, future PM app — all share the three-tier `tenant → app → resource` skeleton. Each app extends with resource-type definitions specific to its domain.
5. **The control plane and the data plane are separate.** Schema (the model) is reviewed via Git. Relationships (the data) are written by application code through SpiceDB's API.

---

## Component placement

```
                 ┌─────────────────┐
                 │  AuthZEN façade │      HTTP/JSON · OpenID AuthZEN 1.0
   apps/...  →  │   (Go, ~150 LoC)│      POST /access/v1/evaluation
                 └────────┬────────┘
                          │  gRPC + mTLS  (private ClusterIP only)
                          ↓
                 ┌─────────────────┐
                 │     SpiceDB     │      schema + relationships
                 │  (1 replica,    │      pre-shared key auth (K8s Secret;
                 │   in-cluster)   │       OpenBao migration in Phase 5)
                 └────────┬────────┘
                          │  TLS  (sslmode=require, mode tightened in
                          │        production hardening)
                          ↓
                 ┌─────────────────┐
                 │  Postgres CNPG  │
                 │ secforge-spicedb│
                 │      -db        │
                 └─────────────────┘
```

Three boundaries:

- **AuthZEN façade ↔ SpiceDB** (cluster-internal gRPC + mTLS). The façade is the single concentration point for app-side traffic into SpiceDB. Apps never speak gRPC directly; they speak HTTP/JSON to the façade.
- **SpiceDB ↔ Postgres** (cluster-internal TLS). All schema and relationships live in `secforge-spicedb-db` (Phase 1). One database, one schema; no per-tenant DBs.
- **App ↔ AuthZEN façade** (cluster-internal HTTP, eventually mTLS via Istio Ambient in Phase 6). The façade exposes a stable, vendor-neutral API; behind it we could swap SpiceDB for Cedar or OpenFGA without changing app code.

The SpiceDB API is **never** exposed via Ingress. Only the façade has a Service that anything outside the spicedb namespace consumes, and even the façade is in-cluster only.

---

## Schema (three-tier)

The schema lives in `infrastructure/spicedb/schema.zed`. Editing is via PR review — see [ADR-0008](../02-decisions/0008-authz-schema.md) for the design and rationale. Here is the canonical version:

```zed
definition user {}

definition tenant {
    relation admin: user
    relation member: user

    permission administer = admin
    permission view       = admin + member
}

definition app {
    relation tenant: tenant
    relation admin:  user
    relation user:   user

    permission administer = admin + tenant->admin
    permission use        = admin + user + tenant->member
}

definition document {
    relation app:    app
    relation owner:  user
    relation editor: user
    relation viewer: user

    permission edit   = owner + editor + app->administer
    permission view   = owner + editor + viewer + app->administer + app->use
    permission delete = owner + app->administer
}
```

### Three tiers, in order

1. **`tenant`** — the customer organization. A tenant has admins (full power within the tenant) and members (can use the tenant's apps).
2. **`app`** — a logical product instance bound to a tenant. The same app type (e.g. Proposal Forge) gets one `app:*` per tenant. Apps have admins (per-app authority) and users (per-app access). A tenant admin inherits administer on every app in their tenant.
3. **`<resource>`** (here `document`) — the per-app resource types. Each app extends the schema with its domain types. A resource is bound to one app via the `app:` relation. Owners, editors, viewers are per-resource roles. App admins inherit edit/delete/view on every resource in the app. App users inherit view.

This stratification is the core of the model: the three tiers are *orthogonal* (each adds its own roles) and *composing* (each tier inherits power from the one above). New resource types extend the bottom tier without touching `tenant` or `app`.

### Per-app extensions

Each application brings its own resource types when it ships:

- **Hello World** (Phase 9): `document` only — what's in the schema today.
- **Proposal Forge** (Phase 10): `proposal`, `section`, `comment`, `attachment` — TBD when Phase 10 designs the model.
- **Project Tracker** (Phase 10): `project`, `task`, `milestone`, `attachment` — TBD.
- **Future PM app**: TBD.

Adding a resource type is a schema PR + a SpiceDB schema migration. Existing relationships and existing resource types are unaffected.

### Object-ID convention

In production code, object IDs are **tenant-prefixed**: `document:tenant_acme/welcome`, not `document:welcome`. This makes accidental cross-tenant references syntactically obvious in logs and prevents two tenants from minting colliding resource IDs. The Phase 4.4 seed data uses unprefixed IDs because there's only one tenant in the demo; Phase 9+ apps generate prefixed IDs from day one. Documented in [ADR-0008](../02-decisions/0008-authz-schema.md).

---

## API surface

### SpiceDB native (gRPC)

SpiceDB speaks the standard SpiceDB API at `spicedb.spicedb.svc:50051` (gRPC, mTLS). Anything inside the cluster with a network path and the pre-shared key can call:

- `WriteRelationships` / `DeleteRelationships` — modify the relationship graph
- `CheckPermission` — yes/no for a (subject, permission, resource) tuple
- `LookupResources` / `LookupSubjects` — list resources/subjects matching a permission
- `ReadRelationships` — paged read
- `WriteSchema` / `ReadSchema` — schema management (Phase 4.4 onward this is restricted to operators)

### AuthZEN façade (HTTP/JSON)

The façade at `authzen-facade.app.svc:8443` (HTTP today; TLS via Istio Ambient in Phase 6) implements OpenID AuthZEN 1.0:

```http
POST /access/v1/evaluation
Content-Type: application/json
Authorization: Bearer <DPoP-bound JWT issued by Keycloak>

{
  "subject":  { "type": "user",     "id": "alice" },
  "action":   { "name": "view" },
  "resource": { "type": "document", "id": "tenant_acme/welcome" }
}

200 OK
{ "decision": true, "context": { "zedtoken": "..." } }
```

The façade is the only thing apps target. Translating AuthZEN to SpiceDB CheckPermission is mechanical: subject → `user:alice`, action.name → permission, resource → `document:tenant_acme/welcome`. The façade returns only the decision — no relationship details leak to the caller. ZedToken is forwarded so the caller can chain a write+check sequence with consistency guarantees.

### What the façade does NOT do

- **Issue tokens.** Keycloak issues; the façade verifies (or trusts the upstream BFF that already verified).
- **Mint relationships.** Apps write relationships directly to SpiceDB through their server-side authn-attested client. The façade is read-only (CheckPermission only, no Write).
- **Cache decisions.** SpiceDB's own dispatch cache covers steady state; layering a second cache in front re-introduces the cache-coherency problem the dispatch cache was designed to solve.

---

## Consistency model

SpiceDB exposes three consistency levels for CheckPermission:

| Level | Use case | Latency cost | Staleness cost |
|---|---|---|---|
| `minimize_latency` | best-effort reads where staleness is OK | none | up to a few seconds |
| `at_exact_snapshot` | reads with an explicit `ZedToken` (returned from a previous write) | bounded by single revision | none |
| `at_least_as_fresh` | reads after a recent write, when the caller has the ZedToken | typically zero | none |
| `fully_consistent` | nuclear option — forces a fresh read | up to a database round-trip | none |

**Convention.**
- **Read-your-writes flows** (write a relationship, then immediately check) — pass the ZedToken from the write into the check with `at_least_as_fresh`.
- **Reads on a request from the user, where the write was on a previous request** — `minimize_latency` is fine; the dispatch cache handles it.
- **Audit / reporting reads** that must reflect the latest state — `fully_consistent`.

We do **not** use `at_exact_snapshot` directly; `at_least_as_fresh` covers it without coupling the caller to a specific revision.

---

## Pre-shared key (interim)

SpiceDB authenticates clients with a pre-shared key (PSK). Today the PSK lives in a Kubernetes Secret in the `spicedb` namespace (`spicedb-preshared-key`). Phase 5 (OpenBao) migrates this to a SPIFFE-bound dynamic secret: clients fetch a short-lived PSK from OpenBao using their JWT-SVID; SpiceDB validates the PSK on each request.

For now, the PSK is rotated by:
1. Generating a fresh value in the Secret
2. Updating the SpiceDB CR to reference both old and new keys (a list)
3. Restarting the AuthZEN façade and any direct SpiceDB clients to pick up the new key
4. After all clients are confirmed using the new key, removing the old key from the SpiceDB CR

The migration playbook to OpenBao (Phase 5) replaces this entire procedure.

---

## Pod and network posture

### Pod hardening

Same standard as the rest of the platform (PSS `restricted` enforced):

- `runAsNonRoot: true`, `runAsUser: 65532` (SpiceDB's distroless default)
- `readOnlyRootFilesystem: true` — SpiceDB doesn't write to the FS at runtime
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

### Workload identity

SpiceDB pod gets a SPIFFE ID `spiffe://secforge.local/ns/spicedb/sa/spicedb` via the SPIFFE-CSI volume. Used in Phase 5 for OpenBao credential fetch (SpiceDB pulls its Postgres credential and PSK rotation from OpenBao via JWT-SVID).

### Network policy

Default-deny ingress in `spicedb` namespace; explicit allow rules:

- `app` namespace pods → SpiceDB:50051 (gRPC, the AuthZEN façade)
- `spicedb-operator` (system) → SpiceDB metrics/health
- `observability` ns → SpiceDB metrics (Phase 7 Prometheus)

Egress for the SpiceDB pod:

- DNS (kube-system)
- Postgres (`cnpg.io/cluster: secforge-spicedb-db` in same namespace)
- OTel collector (Phase 7 — pre-allowed)

The Postgres pod's ingress is opened separately to allow SpiceDB connections (same lesson as Phase 3.6 — default-deny applies cluster-wide and we have to explicitly allow Postgres-side ingress too).

---

## Resource budget

| Resource | Request | Limit |
|---|---|---|
| Memory | 256 Mi | 512 Mi |
| CPU | 100 m | 500 m |

SpiceDB is small. The dispatch cache lives in the pod's heap; for a single-tenant Hello World, 256 Mi is generous. The cloud edition runs 3+ replicas behind a Service; locally one replica suffices.

---

## What changes at cloud migration

1. **Postgres**: in-cluster CNPG → managed Postgres (RDS / Cloud SQL).
2. **Pre-shared key**: K8s Secret → OpenBao-issued, JWT-SVID-bound, short-lived PSK.
3. **mTLS**: cert-manager → Istio Ambient + SPIRE (transparent mTLS replaces SpiceDB's own server cert).
4. **Replicas**: 1 → 3+ behind a Service with a regional / multi-AZ topology.
5. **Schema migrations**: applied via `zed schema write` in a CI step, not interactively.

Application code (the AuthZEN façade contract) does not change.

---

## What is *NOT* in this phase

- **No Caveats** — SpiceDB's caveats feature (conditional permissions evaluated at check-time against per-request context) is powerful but adds complexity. Adding it is a schema PR + a façade-side context-passing change, deferred to whichever app first needs it (likely Proposal Forge for time-boxed access).
- **No Lookup endpoints in the façade.** AuthZEN 1.0 only specifies evaluation. `LookupResources` / `LookupSubjects` use cases (e.g. "list the documents this user can view") will be added when an app needs them; current apps walk the relationship graph from the resource side.
- **No Caveats-based ABAC, no time-of-day rules, no IP geofencing.** Pure ReBAC for now.
- **No request-context-aware decisions** (e.g. "alice can edit only if MFA was used in the last hour"). Step-up auth is a Keycloak/BFF concern; SpiceDB sees only "alice tried to edit document:X."
