# ADR-0029: Per-App Database Strategy — Separate DBs with a Canonical Spine

**Status**: Accepted
**Date**: 2026-05-08 (slot claim) · 2026-07-06 (backfilled from the DB-unification plan)
**Decision-makers**: Project owner
**Relates**: builds on [ADR-0018](./0018-multi-tenancy-rls-strategy.md) (RLS within each DB); implemented by `db-unification/DB-UNIFICATION-PLAN.md` (Binding Decisions D1–D14).

## One-line description

Each ecosystem app keeps its **own logical Postgres database** (separate DBs on one
CNPG cluster initially, splittable to dedicated clusters later). Ecosystem Control owns
the **canonical entities** (orgs, memberships, roles, app catalog, and — per
[ADR-0041](./0041-canonical-core-data-spine.md) — people/clients/engagements). Per-app
DBs reference those by **logical foreign key** (UUID columns, no physical FK across DBs)
and receive **read-only local projections** kept fresh by a Control outbox push + nightly
reconcile. All cross-app data flow goes through **authenticated Control APIs / events —
never cross-database SQL.**

## Context

The platform grew as five well-secured but independent app DBs (Ecosystem Control, Member
Hub, Proposal Forge, Business Manager, Project Manager) synced by ad-hoc pointer columns.
The open question ADR-0018 did not decide was "one database or many." The operator's
instinct that the platform "isn't a cohesive database" is correct — but the fix is **not**
one merged physical database.

## Decision

**Separate databases + a canonical spine in Control.** Concretely:

1. **System of record.** Control owns cross-app entities. Apps create them **through
   Control APIs** and get the canonical row back synchronously, upserting a local
   projection in the same request (no read-after-write race).
2. **Projections are read-only local tables** (`core_people`, `core_clients`,
   `core_engagements`) refreshed by a Control outbox → per-app `/system/core-sync` push
   plus a reconcile sweep. Apps may FK against projections because projection rows are
   soft-deleted (`active=false`), never hard-deleted.
3. **Apps keep owning their domains** (proposals, pursuits, WBS, memberships,
   credentialing, billing) and reference `person_id` / `client_id` / `engagement_id` as
   logical FKs.
4. **No cross-database SQL, ever.** Everything crosses the boundary via API/event. This is
   what keeps the multi-box future a connection-string change.

RLS ([ADR-0018](./0018-multi-tenancy-rls-strategy.md)) continues to apply **within** each
DB — this ADR only decides DB topology, not tenancy enforcement.

## Why NOT one merged database

- Cross-app FKs would weld five independently-deployed apps into a migration-lockstep
  monolith.
- Per-app DB credentials are the least-privilege boundary — one shared DB means
  platform-wide lateral movement from any single app compromise.
- The RLS policy surface would multiply.
- The stated goal of leaving the single box later becomes a near-impossible untangling.
  Separate DBs with a canonical spine split trivially: dump, restore, change a connection
  string in OpenBao.

## Consequences

- **Positive**: least-privilege boundaries preserved; apps deploy independently; the
  multi-box split is a connection-string change; fleet data standards are enforced by the
  conformance harness (`db-unification/specs/data-standards.md §6`,
  `platform/scripts/db-conformance.sh`).
- **Cost**: eventual consistency for projections (cheap on one box today — same-process
  latency); a Control outbox/sync surface to own; the canonical write path adds one API
  hop on entity creation.
- **Physical consolidation** (one `ecosystem-db` CNPG cluster, five databases; keycloak +
  spicedb keep dedicated clusters) is an OPTIONAL, recommended later step — see the
  `db-unification/specs/physical-consolidation.md` spec — executed only after the spine
  phases land. It changes physical packing, not this logical decision. **Executed 2026-07-08 —
  see [ADR-0044](./0044-physical-db-consolidation.md).** This ADR's logical decision is
  unchanged by it (still five databases, five roles, no cross-DB SQL, splittable).

## Status of implementation

Tracked in `db-unification/PROGRESS.md`. **Shipped**: P0 (fleet data standards + conformance
harness + security fixes), the canonical entities (P1 people → P2 clients → P3 engagements),
P4 convergence, and the P5 physical consolidation ([ADR-0044](./0044-physical-db-consolidation.md))
all landed by 2026-07-08.
