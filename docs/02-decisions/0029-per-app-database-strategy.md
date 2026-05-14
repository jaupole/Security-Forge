# ADR-0029: Per-App Database Strategy — Separate DBs with Shared UUIDs

**Status**: In progress (stub — slot reserved)
**Date**: 2026-05-08 (slot claim); content TBD when implemented
**Decision-makers**: Project owner

## One-line description

Each ecosystem app gets its own logical Postgres database (separate DBs on the same cluster initially, splittable to dedicated clusters later). The control plane DB owns canonical UUIDs for orgs, users, roles, app catalog, approvals. Per-app DBs reference those IDs as **logical foreign keys** (no physical FK across DBs). Cross-app data flows go through API/event integration, never cross-DB joins.

## Context to be filled in

This stub reserves the slot per CLAUDE.md ADR conventions. Full content lands when the second app's DB is provisioned (Phase 5 of the ecosystem identity plan).

Builds on but does not supersede [ADR-0018](./0018-multi-tenancy-rls-strategy.md) — RLS continues to apply within each app DB; this ADR addresses the question "one DB or many" that ADR-0018 didn't explicitly decide.

See:
- Plan file: `C:\Users\jaupo\.claude\plans\alright-need-you-to-crispy-sunset.md` §1.1 for the decided strategy and the alternatives table.
