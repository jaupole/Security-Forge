# ADR-0041: Canonical Core Data Spine — People, Clients, Engagements

**Status**: Accepted
**Date**: 2026-07-06
**Decision-makers**: Project owner
**Relates**: extends [ADR-0029](./0029-per-app-database-strategy.md) (per-app DBs + canonical spine). Design + DDL: `db-unification/specs/core-schema.md`; binding decisions D2–D7 in `db-unification/DB-UNIFICATION-PLAN.md`.

## One-line description

Ecosystem Control gains three **canonical cross-app entities** — `people`, `clients`, and
`engagements` (+ `engagement_links`) — that every app references by UUID and receives as
**read-only local projections**. This ends the platform's six-representations-of-a-person,
no-canonical-client, and scattered-pointer-golden-thread problems without merging databases.

## Context (the incohesion this fixes)

- **F1 — six representations of a person.** Keycloak, Control (bare subs + denormalized
  `user_email`), PF `users`, BM `users` **and** BM `people`, PM free-text `person_label`,
  MH `members` (no KC link) + `user_identity_cache`. Name/email for one human lived in 7+
  unsynchronized places.
- **F2 — no canonical client.** PF `projects.client_name` (free text), BM `agency`/`client`
  (free text ×3), PM `custom_fields->>'clientName'` (JSON). Cross-app revenue-by-client was
  unanswerable.
- **F3 — the golden thread is scattered pointers.** Pursuit→proposal→award→project linkage
  lived in BM `pf_project_id`, BM `pm_project_id`, Control `award_handoffs`, and PM
  `sourceProposalId` (an unindexed JSON string). No single place answered "show this deal
  end-to-end."

## Decision

Add to Control (per [ADR-0029](./0029-per-app-database-strategy.md)'s spine):

1. **`people`** (P1) — org-scoped person directory. `person_id` (UUIDv7) is the canonical
   human key; `kc_sub` lives on the row and is **nullable** (roster/import people never log
   in). Email is encrypted (OpenBao Transit) + HMAC'd from day 1. Attribution columns
   (created_by, audit, work_items, memberships) KEEP bare subs — they are not directory
   references. Roster-type references (assignees, owners, contacts) move to `person_id` (D4).
2. **`clients`** (P2) — org-scoped counterparty registry + aliases. PF/BM/PM client
   references converge on `client_id`; free-text client columns become read-only legacy
   during transition, then drop. MH `sponsors`/`prospects` are NOT merged (different domain)
   — revisit after P3 (D6).
3. **`engagements` + `engagement_links`** (P3) — the cross-app deal thread, backfilled from
   the existing pointers. BM↔PF sync, PF→PM handoff, and the BM PM-poller carry
   `engagement_id` going forward; the ad-hoc pointer columns retire after P3 (D7).

**Write path (D3):** canonical writes go **through Control APIs**; the API response carries
the canonical row and the calling app upserts its projection **synchronously** (no
read-after-write race). A Control outbox → per-app `/system/core-sync` push + a reconcile
sweep keep every other app eventually consistent. Projection rows are **soft-deleted only**
(`active=false`) so apps can FK them safely.

Standards: new/core tables use UUIDv7 ids, `*_cents BIGINT` money, timestamptz, snake_case
plural, and the `org_id` + FORCE-RLS template (`specs/data-standards.md §3`). A `version`
column bumps on every UPDATE to order sync.

## Alternatives rejected

- **Merge into one database** — rejected in [ADR-0029](./0029-per-app-database-strategy.md)
  (migration-lockstep monolith; least-privilege boundary lost).
- **Dual-write choreography** — unnecessary: every app DB is <20 MB, so snapshot-and-cutover
  backfills are one-transaction jobs today (D13). This gets strictly more expensive every
  month it waits.
- **Leave apps to reference each other directly** (`<app>_entity_id` pointers) — that is
  exactly F3; deprecated after P3 in favour of `engagement_links` via Control (D7).

## Consequences

- One canonical answer to "who is this person / who is this client / show this deal
  end-to-end," with per-app autonomy preserved (apps read projections, own their domains).
- New surface to own: three entity APIs, the outbox/sync push, and a reconcile job in
  Control; a projection table trio (`core_people`/`core_clients`/`core_engagements`) in each
  app.
- Ambiguous client dedupe (F2 backfill) produces a review file for the operator — human
  adjudication, not silent merges (P2).

## As-built (shipped 2026-07-08) — deltas from the decision above

The decision held; four implementation details settled differently and are now the authoritative
architecture:

- **Transport is PULL, not push.** The "Control outbox → per-app `/system/core-sync` push" above
  was replaced by a pull: each app polls `GET /api/v1/system/core-export?entity=<e>&cursor=<n>`
  with its existing system token. Control had no egress client / app-URL registry / outbound
  token minting, and its egress netpols were deliberately tight — push meant new attack surface.
  Pull is fleet-native (BM already polled PF/PM feeds). The synchronous projection-upsert from the
  Control API response (no read-after-write race) is unchanged. `core_sync_outbox`, the
  subscription registry, and the Control-side worker were removed from scope and **never built**.
- **Per-entity cursors + 24h reconcile.** Each app runs one poller with independent per-entity
  cursors (person/client/engagement), 60s + jitter, version-guarded upserts, and a 24h full
  reconcile from cursor 0 that heals any missed/out-of-order row.
- **Cross-app correlation is engagement-keyed** (P4 wave 3). The ad-hoc pointer columns
  (`pf_project_id`, `pm_project_id`) and free-text client columns (`client_name`, `agency`) were
  **dropped**, not just deprecated; sync and the golden thread key on `engagement_id`.
- **Org scope is manifest-driven** (bm#12): the list of org-scoped models is derived from each
  app's `db/conformance-manifest.json` (fail-closed on drift), not hand-maintained.

Related decisions that landed alongside: the RLS GUC was unified on `app.org_id`
([ADR-0042](./0042-rls-guc-standard-app-org-id.md)); the migration runner/outbox/numbering were
extracted into `@jaupole/ecosystem-db` ([ADR-0043](./0043-ecosystem-db-shared-package.md)); and
the app databases were physically consolidated onto one cluster
([ADR-0044](./0044-physical-db-consolidation.md)) — the projections now live there.

## Status of implementation

**Shipped 2026-07-08.** Entities landed P1 (people) → P2 (clients) → P3 (engagements) →
P4 (convergence: GUC unification, EAV retirement, `users` retirement, pointer/free-text drops),
strictly ordered. Tracked in `db-unification/PROGRESS.md`; `specs/core-schema.md` holds the
authoritative DDL, APIs, and backfill.
