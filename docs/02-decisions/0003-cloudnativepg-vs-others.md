# ADR 0003 — CloudNativePG over Bitnami / Zalando / postgres-operator

**Status:** Accepted
**Date:** 2026-04-28
**Deciders:** SecForge maintainer (J. Aupole)

## Context

Phase 1.4 needs a Postgres deployment pattern for five databases (Keycloak, SpiceDB, OpenBao, Teleport, the apps). Options on the table:

1. **Bitnami `postgresql` Helm chart** — straightforward StatefulSet, no operator, no CRs.
2. **CloudNativePG (CNPG)** — Kubernetes-native operator, custom `Cluster` resource.
3. **Zalando `postgres-operator`** — older, more configurable, more complex.
4. **Crunchy `pgo` operator** — mature, vendor-flavoured, requires acceptance of vendor opinions.

Constraints from CLAUDE.md:
- "No mocks in production paths" — local stack must mirror production behaviour.
- "Defense in depth" — Postgres-level encryption, TLS, and short-lived credentials all matter.
- "Migration paths off local" — local choice should map cleanly to RDS/Cloud SQL.

## Decision

Use **CloudNativePG** for all five Postgres instances. Operator runs in `postgres-operator` namespace; each `Cluster` CR lives in the consuming namespace.

## Rationale

| Property | Bitnami chart | **CNPG** | Zalando | Crunchy |
|---|---|---|---|---|
| First-class K8s operator | no | **yes** | yes | yes |
| Backups to S3 (built-in) | no | **yes** (Barman) | yes (WAL-E) | yes (pgBackRest) |
| Auto-generated app-user secret | no | **yes** | partial | yes |
| TLS server certs (self-managed) | manual | **yes** | manual | yes |
| Maps to RDS/Cloud SQL on migration | manual rewrite | **values swap** | partial | partial |
| Project velocity (last 12 mo) | low | **high** | medium | medium |
| CNCF / vendor-neutral | n/a | **CNCF Sandbox** | community | EDB |
| RAM cost (operator pod) | n/a | ~80 MB | ~150 MB | ~200 MB |

CNPG wins on: native K8s integration, automatic credential management, S3-compatible backups (which line up with our MinIO target without a rewrite), and the cleanest migration path off local (the `Cluster` CR is the only thing tied to in-cluster Postgres; consumer Secrets stay identical).

The Bitnami chart is fine for a one-off database, but managing five of them by hand and maintaining backup/restore procedures is enough work to justify the operator. Zalando is older and the project is less active. Crunchy is solid but bakes in vendor product-line opinions we don't need.

## Consequences

**Positive:**
- One operator + 5 lightweight CRs is less YAML than 5 fully-specified Bitnami charts.
- Future Phase 6 backups land naturally: `Backup` and `ScheduledBackup` CRs targeting our MinIO `backups` bucket.
- Future Phase 5 short-lived credentials work cleanly: OpenBao's database secrets engine talks to `<cluster>-rw` Service.
- App connection-string envFrom pattern is identical local vs cloud (CNPG → ExternalSecrets → RDS Secrets Manager).

**Negative:**
- One more CRD to learn for anyone joining the project. Mitigated by [postgres-instances.md](../06-reference/postgres-instances.md).
- CNPG's image (`ghcr.io/cloudnative-pg/postgresql`) is a Postgres rebuild with their controller-side hooks; not the upstream `postgres` image. That's fine — it's still upstream Postgres binaries, but worth flagging if someone tries to docker pull `postgres:16` and wonders why it's different.

## Alternatives considered

- **Single Postgres pod with multiple databases.** Rejected: blast radius (one Postgres failure takes down all 5 components), credential isolation (one role per app implies one user-facing secret per app, but a single instance complicates pgaudit segregation), and quota accounting (everything bills to one namespace).

## References

- CloudNativePG docs: https://cloudnative-pg.io/documentation/
- Phase 1.4 prompt: [phase-01-foundation.md](../05-claude-code-prompts/phase-01-foundation.md)
- Postgres instance inventory: [postgres-instances.md](../06-reference/postgres-instances.md)
