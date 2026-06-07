# Phase 4 — Authorization Engine (SpiceDB)

> **Navigation:** ⬅ [Previous: Phase 3 — Keycloak](./phase-03-keycloak.md) · [Next: Phase 5 — OpenBao](./phase-05-openbao.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phases 0–3
> **Blocks:** Phases 5–11 (every authorization decision flows through SpiceDB)
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ✅ Complete (2026-04-29). AuthZEN façade live.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2 days

**Prerequisites:** Phases 1-3 complete.

---

## Goal of this phase

Deploy SpiceDB with the three-tier permission schema. Build the AuthZEN façade. Verify CheckPermission works.

---

## What you (the human) need to do first

1. Read the SpiceDB section in `docs/01-architecture/00-overview.md`.
2. Sketch out (paper or doc) the rough permission model for your apps. For Hello World we'll keep it minimal but think ahead to Proposal Forge and Project Tracker.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 4 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-04-spicedb.md before doing anything.

Your task is to deploy SpiceDB, define the schema, deploy the AuthZEN façade, and verify CheckPermission.

## Phase 4.1 — Design

Document in docs/01-architecture/02-authorization.md:
- Datastore: secforge-spicedb-db Postgres (Phase 1)
- Replicas: 1 in local edition; HA in cloud later
- API: gRPC, mTLS in cluster; bridged to HTTP via the AuthZEN façade
- Pre-shared keys: K8s Secret for now; migrate to OpenBao in Phase 5
- Schema source of truth: `infrastructure/spicedb/schema.zed` in this repo

## Phase 4.2 — Initial schema

Create infrastructure/spicedb/schema.zed:

```
definition user {}

definition tenant {
    relation admin: user
    relation member: user

    permission administer = admin
    permission view = admin + member
}

definition app {
    relation tenant: tenant
    relation admin: user
    relation user: user

    permission administer = admin + tenant->admin
    permission use = admin + user + tenant->member
}

definition document {
    relation app: app
    relation owner: user
    relation editor: user
    relation viewer: user

    permission edit = owner + editor + app->administer
    permission view = owner + editor + viewer + app->administer + app->use
    permission delete = owner + app->administer
}
```

Add Validator test files in `infrastructure/spicedb/tests/` proving:
- An owner can edit
- A viewer can view but not edit
- A non-relationship user cannot view
- A tenant admin can administer all apps in the tenant

## Phase 4.3 — Deploy SpiceDB

Use the SpiceDB Operator. Deploy:
- 1 replica
- Postgres backend
- mTLS enabled (server cert from cert-manager)
- gRPC service exposed only on a private ClusterIP, not via Ingress
- Pre-shared key as a Secret
- OpenTelemetry tracing enabled (will hook to Tempo in Phase 7)
- Audit logs as structured JSON to STDOUT
- SPIFFE-CSI volume, identity = `spiffe://secforge.local/ns/spicedb/sa/spicedb`

## Phase 4.4 — Apply schema and seed test data

Use `zed` CLI to apply the schema. Then seed:
```
zed relationship create tenant:helloworld#admin user:jason
zed relationship create tenant:helloworld#member user:alice
zed relationship create app:helloworld-app#tenant tenant:helloworld
zed relationship create app:helloworld-app#user user:alice
zed relationship create document:welcome#app app:helloworld-app
zed relationship create document:welcome#owner user:jason
zed relationship create document:welcome#viewer user:alice
```

## Phase 4.5 — Test CheckPermission

Verify expected results:
- `document:welcome view user:jason` → ALLOWED
- `document:welcome view user:alice` → ALLOWED
- `document:welcome edit user:jason` → ALLOWED
- `document:welcome edit user:alice` → DENIED
- `document:welcome view user:bob` → DENIED

Test ZedToken consistency:
- Write a relationship, get the ZedToken
- Pass it to a CheckPermission with consistency `at_least_as_fresh`
- Verify the check sees the latest data

## Phase 4.6 — AuthZEN façade

Create a small Go service (~100 lines) at `apps/authzen-facade/`:
- Exposes the OpenID AuthZEN 1.0 Authorization API (https://openid.net/specs/authorization-api-1_0.html)
- Translates AuthZEN POST /access/v1/evaluation requests to SpiceDB CheckPermission
- Returns `{ "decision": true|false }`

Containerize, sign with Cosign (using the local key from Phase 1), deploy 2 replicas in `app` namespace. ClusterIP service.

## Phase 4.7 — Documentation

Update:
- docs/01-architecture/02-authorization.md
- docs/02-decisions/0004-authz-schema.md (the schema and its rationale)
- docs/03-runbooks/spicedb-operations.md (schema migrations, recovery)
- infrastructure/spicedb/schema.zed (in version control)
- infrastructure/spicedb/tests/ (validator test files)

## Constraints

- SpiceDB API is gRPC + mTLS only, never plaintext, never publicly exposed
- Schema changes go through PR review
- Pre-shared keys planned for OpenBao migration
- Audit log every CheckPermission to STDOUT
- Object IDs in production code are tenant-prefixed
```

---

## Success criteria

- [ ] SpiceDB deployed, healthy, gRPC reachable from inside cluster
- [ ] Postgres backend connected
- [ ] Schema loaded and validates
- [ ] Test data inserted; CheckPermission returns expected results
- [ ] ZedToken consistency works
- [ ] AuthZEN façade deployed and proxies correctly
- [ ] Validator tests in version control
- [ ] Documentation updated
- [ ] PLAN.md updated

---

## Troubleshooting

### "zed: connection refused"
`zed` needs `--token <preshared-key>` and a port-forward (or to be run from inside the cluster).

### "Schema validation fails"
Use https://play.authzed.com/ to debug schema syntax.

### "Slow checks"
Enable the dispatch cache. Most checks should serve from cache, not hit Postgres.

---

## What's next

[Phase 5 — Secrets Management (OpenBao)](./phase-05-openbao.md).
