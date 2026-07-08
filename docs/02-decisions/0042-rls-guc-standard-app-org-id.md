# ADR-0042: Fleet RLS session-context standard — `app.org_id` / `app.user_id`

**Status**: Accepted
**Date**: 2026-07-08
**Decision-makers**: Project owner
**Relates**: refines [ADR-0018](./0018-multi-tenancy-rls-strategy.md) (RLS within each DB) and
[ADR-0029](./0029-per-app-database-strategy.md) (per-app DBs). Supersedes any earlier text that
names an app-specific GUC (e.g. `app.current_org_id`). Executed in DB-unification P4 wave 1.

## One-line description

Every app's Row-Level Security uses the **same two PostgreSQL session GUCs** — `app.org_id`
(the active tenant) and `app.user_id` (the acting principal) — set per-transaction via
`SET LOCAL` / `set_config(...)`. No app-specific GUC names.

## Context

The apps grew independently and each invented its own session-context variable name for the
`SET LOCAL` tenant-scoping pattern (Member Hub and Project Manager used app-specific names;
others used `app.org_id`). RLS policies, `SECURITY DEFINER` functions, and the per-request
`set_config` calls all had to agree per-app. That divergence blocked three fleet-wide things:

- the conformance harness (`platform/scripts/db-conformance.sh`) could not run a single
  **strict-mode** check for the GUC across all five apps;
- the shared `@jaupole/ecosystem-db` runner + the canonical-core RLS template
  (`db-unification/specs/data-standards.md §3`) assume one GUC name;
- a reader auditing any app had to remember which name was in play.

## Decision

Standardise on **`app.org_id`** (tenant) and **`app.user_id`** (actor) for RLS session context
across all five app databases. Policies read `current_setting('app.org_id', true)::uuid`;
request middleware / repo helpers set them with `SET LOCAL` inside the transaction. This is the
name the canonical-core template and the conformance harness strict mode enforce.

Migrated in P4 wave 1 by **regenerating every live policy** against the new GUC (MH migration
137 — 42 policies; PM migration 031 — 52 policies, with a self-asserting `DO` block), after
proving no `SECURITY DEFINER` function, default, or view read the old GUC. Applied SQL is
policy-for-policy equivalent; only the GUC name changed.

## Consequences

- **Positive**: one mental model fleet-wide; the conformance harness runs strict-mode GUC
  checks 5/5; the shared runner and new-app `db/` template (D14) drop in without per-app GUC
  wiring.
- **Cost**: a one-time full-policy rewrite per diverging app (done, verified: 0 old-GUC
  policies remain).
- New apps inherit the standard from the template — no decision to re-make.

## Status

Shipped 2026-07-08 (P4 wave 1). Tracked in `db-unification/PROGRESS.md`. Enforced going forward
by the conformance harness strict mode.
