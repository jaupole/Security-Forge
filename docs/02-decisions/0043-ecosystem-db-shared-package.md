# ADR-0043: `@jaupole/ecosystem-db` — shared migration runner, outbox, numbering

**Status**: Accepted
**Date**: 2026-07-08
**Decision-makers**: Project owner
**Relates**: supports [ADR-0029](./0029-per-app-database-strategy.md) (per-app DBs) and
[ADR-0041](./0041-canonical-core-data-spine.md) (canonical spine). Mirrors the packaging model
of `@jaupole/ecosystem-auth`. Executed in DB-unification P4 tail.

## One-line description

The three near-identical bespoke migration runners (Control, Member Hub, Project Manager) are
extracted into one ESM package, `@jaupole/ecosystem-db`, with three independently-importable
exports: `/migrate`, `/outbox`, `/numbering`.

## Context

Control, MH, and PM each carried their own hand-written migration runner (~100–150 lines).
They had drifted in incidental ways while sharing the same contract (each migration owns its
`BEGIN/COMMIT` + `schema_migrations` bookkeeping; files applied once, in order). Three copies
meant three places to fix a bug and three subtly-different behaviours. The outbox-claim and
numbering-allocator patterns were also being re-implemented per app.

## Decision

Publish `@jaupole/ecosystem-db` (ESM — all consumers are NodeNext ESM), vendored into each app
as a `file:vendor/*.tgz` tarball exactly like `@jaupole/ecosystem-auth`:

- **`/migrate`** — the single runner, parameterised ONLY on the real divergences:
  `roleStrategy` (Control's `SET ROLE control_owner` + the guarded `060` FORCE-RLS
  superuser-cutover migration + `RESET ROLE`) and `.down.sql` exclusion. MH/PM pass no
  `roleStrategy` → the plain loop. Applied SQL is byte-identical to the old runners.
- **`/outbox`** — `createOutboxSql()` (mature post-`126` shape: `next_attempt_at` gate,
  `FOR UPDATE SKIP LOCKED`, 5-min reclaim, `SECURITY DEFINER`) + a typed claim repo.
  **New-code only** — existing live outboxes are grandfathered, not migrated.
- **`/numbering`** — `createNumberingConfigSql()` (the D10 standard on the unified
  `app.org_id` GUC) + an allocator. **New-code only** — the ~7 existing numbered tables are
  grandfathered.

Adopted as a thin (~15-line) wrapper per app, in order **PM → MH → Control** (Control last —
it exercises the `roleStrategy` path). Provenance repo: `github.com/jaupole/ecosystem-db`
(private); npm publish + CI + cosign signing gated behind an operator step (the vendored
adoption does not require the published package).

## Alternatives rejected

- **Leave three runners** — the drift-and-triplicate-fix cost only grows; the runner is the
  single riskiest piece of shared DB machinery (it applies FORCE-RLS cutovers).
- **A git submodule / copy-paste module** — loses versioned, vendored, byte-reproducible
  builds; `ecosystem-auth` already proved the `file:vendor/*.tgz` model on this fleet.

## Consequences

- **Positive**: one place to fix migration-runner behaviour fleet-wide; Control CI applying its
  full ~107-migration chain (incl. the 060 FORCE-RLS cutover) through the shared runner is the
  strongest regression proof. Outbox/numbering standardised for new code.
- **Cost**: a vendored tarball to re-roll on package changes (same overhead as ecosystem-auth);
  publish/provenance still owed for supply-chain hygiene (does not block adoption).

## Status

Shipped 2026-07-08 (P4 tail). Adopted PM/MH/Control. Tracked in `db-unification/PROGRESS.md`.
