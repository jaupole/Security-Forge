# ADR-0044: Physical DB consolidation — one `ecosystem-db` cluster, five databases

**Status**: Accepted
**Date**: 2026-07-08
**Decision-makers**: Project owner
**Relates**: **executes the optional physical-consolidation step already permitted by**
[ADR-0029](./0029-per-app-database-strategy.md) (§Consequences). Does NOT change the ADR-0029
logical decision. Connection-secret DR model: [ADR-0015](./0015-secret-distribution-pattern.md)
(VSO). Spec: `db-unification/specs/physical-consolidation.md`; runbook:
`docs/03-runbooks/ecosystem-db-operations.md`.

## One-line description

The five app databases (`control`, `member_hub`, `proposal_forge`, `business_manager`,
`project_manager`) now live as five databases on ONE CNPG cluster, `ecosystem-db/ecosystem-db`,
instead of five single-instance clusters. Keycloak and SpiceDB keep their own clusters.

## Context

ADR-0029 chose separate logical databases and explicitly noted physical consolidation as an
"OPTIONAL, recommended later step … [that] changes physical packing, not this logical
decision," to be done after the spine phases (P1–P3) land. They landed (P1–P4). The five
clusters together held ~71 MB of data yet each carried a full CNPG operator-managed instance:
its own primary pod, WAL stream, base-backup schedule, ObjectStore, and resource floor —
five times the fixed overhead for a trivial data volume on a single node.

## Decision

Consolidate onto one `ecosystem-db` CNPG cluster (P5). The **ADR-0029 logical model is
unchanged**: five separate databases, per-app roles/credentials, no cross-database SQL, the
canonical spine reached only via Control APIs, and split-back-out remaining a dump/restore +
connection-string change. Only physical packing changed.

- **Cluster**: 1 instance, 20Gi, tuned once (`max_connections=200`, scram-sha-256, TLS 1.3);
  keycloak + spicedb deliberately excluded (different lifecycles / blast-radius isolation for
  the IdP and the authorizer).
- **Cutover** (per app, gated): load roles up front via `pg_dumpall --roles-only` (reproduces
  the exact role posture AND SCRAM password hashes → only the connection *host* changes), then
  `pg_dump <db> | psql` (plain format — custom format does not restore over a pipe), rowcount-
  gated, then repoint the app's DB env at the new host and scale up. Each app namespace gets an
  egress NetworkPolicy to `ecosystem-db` on 5432 + 15008 (Ambient HBONE).
- **Connection + DR model**: each app reads a `<app>-ecodb` k8s Secret
  (host/port/username/password/dbname/uri). Those secrets are **OpenBao-backed and VSO-rendered**
  ([ADR-0015](./0015-secret-distribution-pattern.md), SF#153) — necessary because CNPG base
  backups carry only SCRAM password *hashes*, so the plaintext app-role passwords must live
  durably in OpenBao. DR = restore the cluster, VSO re-renders every `<app>-ecodb`, apps boot.

## Alternatives rejected

- **Keep five clusters** — five copies of fixed CNPG overhead for ~71 MB; five backup/restore
  procedures, five tuning surfaces, five patch targets.
- **One merged database (shared schema, cross-app FKs)** — still rejected (ADR-0029): that
  welds the apps into a migration-lockstep monolith and destroys the per-app credential
  boundary. Consolidation keeps five *databases* with five *roles*; it is packing, not merging.

## Consequences

- **Positive**: one cluster to tune, back up (daily ScheduledBackup + continuous WAL to MinIO),
  patch, and restore-drill; freed per-app DB resource requests on a single node.
- **Cost / accepted risk**: single-instance blast radius — a `Cluster` spec change (e.g. a
  Renovate image bump) briefly rolls the one instance and momentarily affects all five apps.
  Accepted on a single-node platform; mitigated by `smartShutdownTimeout: 10` (fast shutdown)
  and digest-pinned images. Split any database back out to its own cluster if its lifecycle
  diverges (the ADR-0029 escape hatch, still a dump/restore + connection change).

## Status

Shipped 2026-07-08 (P5). All five apps + their cronjobs cut over and verified; codified in
SF#152 (env repoint) + SF#153 (DR-durable secrets). Old per-app clusters retained ~7 days as a
rollback net, then decommissioned. Tracked in `db-unification/PROGRESS.md`.
