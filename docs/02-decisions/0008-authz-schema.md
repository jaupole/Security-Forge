# ADR-0008: Authorization Schema — Three-Tier ReBAC (tenant → app → resource)

**Status**: Accepted
**Date**: 2026-04-29
**Decision-makers**: Project owner

## Context

The platform externalizes authorization to SpiceDB (Phase 4). The schema is the contract between the application code (which writes relationships and asks "can user X do Y on Z?") and the policy engine (which traverses the graph and answers). Schema changes affect every app on the platform; getting the shape right early avoids a costly migration later.

The platform serves three application types over time:

- **Hello World** (Phase 9 demo) — minimal: documents owned by users.
- **Proposal Forge** (Phase 10) — proposals, sections, comments, attachments; multi-author with per-section permissions.
- **Project Tracker** (Phase 10) — projects, tasks, milestones, attachments; owners + assignees + read-only stakeholders.
- **Future PM app** — undefined.

All three are multi-tenant SaaS with the same authentication realm (`secforge-tenants`) but isolated tenant data. Tenant admins should be able to manage everything within their tenant; tenant members should be able to use apps; per-resource roles (owner/editor/viewer) layer on top.

## Decision

**Adopt a three-tier ReBAC schema with `tenant`, `app`, and per-app resource definitions. Each tier is orthogonal (its own roles add power) and composing (each tier inherits power from the tier above).**

The canonical schema:

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

Source of truth: `infrastructure/spicedb/schema.zed`. Validator tests (assert-true/false against synthetic relationships): `infrastructure/spicedb/tests/`. Both go through PR review for any change.

### Inheritance rules

| User role | App permissions inherited | Resource permissions inherited |
|---|---|---|
| `tenant#admin` | `app#administer` (every app in tenant) | `document#edit`, `view`, `delete` |
| `tenant#member` | `app#use` (every app in tenant) | `document#view` |
| `app#admin` | (n/a — explicit) | `document#edit`, `view`, `delete` |
| `app#user` | (n/a — explicit) | `document#view` |
| `document#owner` | (n/a) | `edit`, `view`, `delete` |
| `document#editor` | (n/a) | `edit`, `view` |
| `document#viewer` | (n/a) | `view` |

A tenant admin doesn't need to be enrolled per-app or per-document; the cascade authorizes them. A tenant member sees every document the apps allow but can't edit unless explicitly granted.

### Object-ID naming convention

In production code, object IDs are **tenant-prefixed**: `document:tenant_acme/welcome` rather than `document:welcome`. This makes accidental cross-tenant references syntactically obvious in logs and prevents tenants from minting colliding IDs.

The Phase 4.4 seed data does NOT prefix (only one tenant in the demo). Phase 9+ apps generate prefixed IDs from day one.

### Per-app extensions

Apps add their own resource definitions (alongside `document`) at deploy time. Pattern:

```zed
definition <app-resource> {
    relation app: app                # back-pointer to owning app
    relation <role-1>: user
    relation <role-2>: user
    ...
    permission <perm> = <role expression> + app->administer + app->use
}
```

Phase 10's design pass for Proposal Forge and Project Tracker will add proposal/section/project/task definitions following this pattern. Existing definitions remain unchanged.

## Rationale

### Why ReBAC (relationship-based) and not RBAC

RBAC needs role explosion to express resource-level permissions ("editor on doc 4471 but not doc 4472"). ReBAC encodes the relationships directly: `document:4471#editor@user:alice` is a single tuple. SpiceDB's evaluation model — graph traversal from resource to subject through relations — is a cleaner mental model for the per-document permissions every app needs.

### Why three tiers and not two or four

- **Two tiers (app + resource)** loses the "tenant admin can administer all their apps" cascade — every tenant admin would need explicit per-app admin grants, and every new app would need a write-fan-out across all tenant admins.
- **Three tiers** covers tenant ownership, product instance, and per-resource roles cleanly with one cascade per layer.
- **Four tiers (e.g., adding a "workspace" between app and resource)** is premature abstraction — none of the apps shipped in Phase 9/10 have a workspace concept that the user model exposes. If a future app needs it, we add `workspace` as a per-app definition between `app` and the resource type.

### Why `app` as a tier and not just a label

If `app` were a label or attribute, we'd need Caveats (per-request context) to gate resources by app — or app-prefixed IDs — and the cascade `tenant#admin → app#administer → document#edit` would have to be expressed by Caveat predicates instead of relations. Both alternatives reduce SpiceDB's graph-traversal advantage. Modeling `app` as a definition with a `tenant` back-pointer makes the cascade a clean graph walk.

### Why permissions are computed, not stored

We could store "user X can edit document Y" as a row in an ACL table updated on every relationship change. We don't, because:

- Adding a new permission rule (e.g., "owner can also share") would require backfilling every existing document's ACL.
- Removing a relationship would require cascading ACL deletes across all derivative permissions.
- Cache coherency between the ACL store and the relationship store would become its own subsystem.

SpiceDB's dispatch cache (in-process LRU keyed by the request graph) handles the read-side performance at orders-of-magnitude less complexity, and the only persistent thing is the relationship graph.

### Why tenant-prefixed object IDs

Without tenant-prefixing, two tenants could theoretically use the same `document:welcome` ID. SpiceDB doesn't reject this — relationships are isolated by the relations attached, not by the ID — but it makes log-grep ambiguity and cross-tenant data-handling bugs catastrophic instead of obvious. With prefixing, `document:tenant_acme/welcome` is unmistakable in audit and in app code.

The prefix is a *convention* enforced in app code, not in the schema. The schema accepts any string ID.

### Why Caveats are not in the baseline schema

SpiceDB's Caveats let permissions depend on per-request context (e.g., "alice can edit only if the request includes a valid step-up assertion"). Powerful but adds a context object to every CheckPermission call and pushes some authorization logic back to the caller's request envelope. We don't add caveats in Phase 4. The first app that genuinely needs them (likely Proposal Forge for time-boxed access) introduces them with a corresponding schema PR.

## Alternatives considered and rejected

### Single global `admin` permission inherited everywhere

**Pros**: simplest mental model.
**Cons**: there's no global admin in this platform — everything is scoped to a tenant. A "global admin" role would punch through every tenant boundary. Rejected.

### Adding a `viewer` role at the `tenant` level

**Pros**: lets the tenant grant org-wide read-only access ("everyone in acme can view all docs in all apps in our tenant").
**Cons**: today, `tenant#member` already cascades into `document#view` via `app->use`. Adding a separate `tenant#viewer` would create a parallel cascade with no current consumer. We can add it later with a schema PR that introduces the relation and the permission expression (no breaking change).
**Decision**: rejected for the baseline; reconsider per app need.

### `permission share = ... + app->administer` on document

**Pros**: would let app admins give away access without being doc owner.
**Cons**: the request "share with user X" is itself a relationship-write operation that's authorized via `edit` (or its own permission). Folding "share" into `view`/`edit` keeps the permission surface small. If a UI surfaces "share document" as a distinct user action, we'd add `permission share = owner + app->administer` then.
**Decision**: not yet.

### Per-tenant key prefix in SpiceDB datastore (table sharding)

**Pros**: physical isolation between tenants.
**Cons**: SpiceDB doesn't natively shard by tenant; doing so means running multiple SpiceDB clusters. Operational overhead is order-of-magnitude higher than the prefix-by-convention approach. Reconsider only if a tenant has measurably different scale-up needs from the rest.
**Decision**: rejected.

### Use Caveats for tenant isolation instead of object-ID prefixes

**Pros**: explicit, schema-encoded.
**Cons**: every CheckPermission would need a `tenant_id` context object, increasing payload size and operational complexity for a property that's already enforceable by ID convention.
**Decision**: rejected.

## Consequences

### What this commits us to

- Every app's BFF or AuthZEN-façade-using service writes relationships to SpiceDB through a server-side, authn-attested client. No client-side relationship writes.
- Object IDs in production code are tenant-prefixed (`document:tenant_<id>/<resource_id>`). Convention enforced in code review and (eventually) by linter.
- New resource types are added via schema PR + a SpiceDB schema migration. Existing relationships and types are unaffected.
- The validator test suite (`infrastructure/spicedb/tests/`) is the canonical regression check for permission rules. Adding a permission rule means adding a test.
- Tenant admins implicitly get `delete` on every document in their tenant. App-side UX must surface "this user is a tenant admin and can delete things" so it's not surprising.

### What this preserves

- Schema migration path: new tiers (e.g., a `workspace` between app and resource) are additive — define a new type and update the affected resource's `permission` expressions.
- Caveats path: when first needed, add them per-permission without breaking existing ones.
- Multi-instance apps: multiple `app:helloworld-app-tenant_acme`, `app:helloworld-app-tenant_globex` etc. — same schema serves all.

### Known gaps

1. **No row-level filter for `LookupResources`.** "List documents alice can view" is paginated by SpiceDB but doesn't include caveats; if we add caveats later, list operations become more involved.
2. **No tenant-isolation enforcement at the schema level.** Two tenants writing the same object ID (e.g., both creating `document:welcome`) would collide unless app code prefixes. Convention, not enforcement.
3. **No audit of "who changed which relationship when."** SpiceDB has the Watch API for stream consumers but not a "who-modified-what" audit table out of the box. If we need this, we add it via app-side write logging or by a SpiceDB Watch consumer that emits to Wazuh.

## Re-evaluation criteria

Re-open this ADR if:

1. Two tenants need to share a single resource (cross-tenant sharing is not in the model today).
2. An app needs request-context-dependent permissions (step-up auth, time-of-day, IP geofence) — that's the trigger for adding Caveats.
3. The cascade depth (currently 2: tenant → app → resource) becomes a performance bottleneck (it shouldn't; SpiceDB is built for this).
4. A new app requires a fundamentally different relationship topology that doesn't fit the three-tier model.

## References

- [docs/01-architecture/02-authorization.md](../01-architecture/02-authorization.md) — architecture as deployed.
- [infrastructure/spicedb/schema.zed](../../infrastructure/spicedb/schema.zed) — source of truth.
- [infrastructure/spicedb/tests/](../../infrastructure/spicedb/tests/) — validator tests.
- [docs/03-runbooks/spicedb-operations.md](../03-runbooks/spicedb-operations.md) — schema migrations + recovery.
- SpiceDB documentation: <https://authzed.com/docs/spicedb>
- Google Zanzibar paper (the ReBAC model): <https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/>
