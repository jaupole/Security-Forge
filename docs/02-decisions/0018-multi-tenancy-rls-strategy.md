# ADR-0018: Multi-tenancy strategy — Postgres RLS + SpiceDB AuthZ (defense in depth)

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

CLAUDE.md line 71 mandates: "Every database query in multi-tenant tables must include the tenant_id filter, AND the table must have a Postgres RLS policy. Defense in depth — same locally and in cloud."

That mandate has never been followed up with an ADR explaining the strategy: which TWO checks (the application-level filter AND the RLS policy), what the RLS policy actually looks like, where `tenant_id` comes from, what the test approach is, and what a future Phase 9+ app does to comply.

Without an ADR, every app re-invents the pattern badly. Phase 9 is the first multi-tenant app land; this ADR exists so Phase 9 doesn't have to make these decisions in flight.

## Decision

Multi-tenant tables are gated by **two independent checks**, each one capable of refusing a leaked-tenant-id request, with both required to pass:

### 1. SpiceDB authorization (primary check)

Before the SQL query runs, the request handler calls SpiceDB through the AuthZN façade ([apps/lib/authzn](../../apps/lib/authzn) — Fix-after-07 §A.4) with:

```go
dec, _ := authzn.Evaluate(ctx, Subject{Type:"user", ID: claims.Sub},
                          "read", Resource{Type:"document", ID: docID})
if !dec.Allowed { return 403 }
```

SpiceDB knows the relationship graph: user → tenant → resource. A user trying to read a document in a tenant they don't belong to gets `Allowed=false` from SpiceDB before any SQL touches a row.

### 2. Postgres Row-Level Security (defense-in-depth)

Even with SpiceDB green-lighting, the application MUST scope every multi-tenant query by `tenant_id`. Postgres RLS enforces this at the row level so an application bug (forgotten WHERE clause) cannot return rows from another tenant.

Schema requirements per multi-tenant table:

```sql
-- Required column on every multi-tenant table.
tenant_id UUID NOT NULL,

-- Recommended index.
CREATE INDEX ON <table> (tenant_id);

-- Required RLS enable + policy.
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;
ALTER TABLE <table> FORCE ROW LEVEL SECURITY;  -- applies even to table owner

CREATE POLICY tenant_isolation ON <table>
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

`FORCE` matters: without it, the app's connection role (which usually owns the table for migration purposes) bypasses the policy. With FORCE, even the owner role is constrained.

### 3. Application-side `SET LOCAL`

Every request handler that touches a multi-tenant table MUST run inside a transaction that has set the tenant context:

```go
tx, _ := db.BeginTx(ctx, nil)
defer tx.Rollback()
if _, err := tx.ExecContext(ctx, "SET LOCAL app.tenant_id = $1",
                            claims.TenantID); err != nil {
    return 500
}
// ... SELECTs / INSERTs / UPDATEs go here ...
tx.Commit()
```

`SET LOCAL` scopes the variable to the current transaction; the connection pool's next checkout doesn't inherit it. The RLS policy reads `app.tenant_id` via `current_setting('app.tenant_id')::uuid`. The cast to UUID is intentional — it forces a parse error rather than a silent string-comparison fall-through if the variable was never set.

### 4. Tenant ID source: JWT claim, never request body

`claims.TenantID` comes from the JWT issued at OIDC login. **A request body field MUST NOT be the source of `tenant_id`** — that would let any user spoof the tenant by editing the body. The Phase 6b-1 `apps/lib/api-auth/Middleware.ValidateInbound` will surface tenant_id as a typed claim (Phase 9 wires this end-to-end).

For now (Phase 6 BFF, no backend yet), the BFF carries the `sub` claim through to the backend. The backend resolves `sub` → `tenant_id` via a `users` table lookup. Phase 9's backend implementation makes this explicit.

## Why TWO checks instead of one

Either check on its own is insufficient:

- **SpiceDB alone** misses: a forgotten WHERE clause in application SQL returns rows the SpiceDB check would have denied if the bug had been on the AuthZ path. SQL-injection bypass routes around the SpiceDB check entirely.
- **RLS alone** misses: complex authorization (cross-tenant grants, role hierarchies, time-bounded permissions) is not natively expressed in `USING` clauses. RLS as the sole check forces gymnastic SQL that becomes its own bug surface.

Both together: the application bug surface (forgotten WHERE) is bounded by RLS; the RLS expressiveness surface (complex AuthZ) is handled by SpiceDB. Each compensates for the other's weakness.

## What MUST NOT change without superseding this ADR

- Removing the RLS policy from a multi-tenant table.
- Sourcing `tenant_id` from a request body, query string, or path parameter rather than from a verified JWT claim.
- Replacing the `SET LOCAL` pattern with a session-level (`SET`) variable that persists across pool checkouts.
- Skipping the SpiceDB check on the assumption that RLS "is enough."

## Test approach (for Phase 9+ apps)

Each multi-tenant repo MUST include integration tests that verify:

1. **Happy path**: user in tenant A reads document in tenant A → 200 OK.
2. **Cross-tenant via SpiceDB**: user in tenant A requests document in tenant B → 403 (SpiceDB denied, RLS never reached).
3. **Cross-tenant via SQL bypass**: a deliberately-broken handler that omits the WHERE tenant_id clause → no rows returned (RLS policy rescues).
4. **No SET LOCAL**: a handler that forgets the SET LOCAL → query returns 0 rows (RLS policy default-denies because `current_setting('app.tenant_id')` is unset and the cast fails).
5. **Spoofed tenant_id in body**: a handler that incorrectly trusts a body-supplied tenant_id → still gets 403 because SpiceDB sees the JWT-derived sub and the body's tenant_id mismatch.

Test #3 and #4 are the critical defense-in-depth tests. Tests that only cover happy + cross-tenant-via-AuthZ leave the RLS layer un-exercised; a regression in the policy goes undetected until production.

## What this ADR does NOT do

- **Provide migration code.** Phase 9 writes the first migration; this ADR specifies the shape, not the SQL files.
- **Mandate a particular ORM or driver.** Go `database/sql` directly works; sqlc works; pgx works. The constraint is the per-tx `SET LOCAL` invariant, not the access pattern.
- **Cover cross-tenant intentional sharing** (e.g., "system admin can see all tenants"). When that requirement lands, supersede this ADR with a successor that defines the role-based bypass explicitly. **Do NOT add a `BYPASSRLS` role** — that's the kind of escape hatch that becomes load-bearing without anyone tracking it.

## Cross-references

- [ADR-0008](./0008-authz-schema.md) — SpiceDB schema (defines the relationship graph this ADR's check #1 evaluates against)
- [`apps/lib/authzn`](../../apps/lib/authzn) — Fix-after-07 §A.4 (the AuthZN interface this ADR's check #1 calls)
- [`apps/lib/api-auth`](../../apps/lib/api-auth) — Phase 6b-1 (the inbound JWT validator that produces the `claims.TenantID` this ADR's #3 reads)
- [`docs/05-claude-code-prompts/phase-09-hello-world.md`](../05-claude-code-prompts/phase-09-hello-world.md) — first consumer
- [Fix after 07 § F-ADR-9](../../Fix%20after%2007/00-audit-findings.md#f-adr-9--high--missing-adr--db-multi-tenancy--rls-strategy) — the audit finding this ADR closes

## Re-evaluation triggers

- A multi-tenant app surfaces a real-world authorization rule that doesn't fit either SpiceDB or `SET LOCAL` (e.g., row-level RLS that depends on time of day) → supersede with a successor ADR rather than carving an exception.
- Postgres major version bump that changes RLS semantics → audit + confirm or supersede.
- A compliance regime that requires per-tenant database isolation (separate Postgres roles, separate schemas, or separate databases) rather than RLS → supersede with the new strategy.
