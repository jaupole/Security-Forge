# Architecture Decision Records (ADRs)

Short, append-only documents that record *why* we chose one approach over another. When you're tempted to argue "we don't need an ADR for this," that's a sign you do.

## Index

| # | Title | Status |
|---|---|---|
| [0001](./0001-local-first.md) | Build Local-First on Docker Desktop Kubernetes | Accepted |
| [0002](./0002-local-passkey-via-windows-hello.md) | Use Windows Hello as Local-Edition Admin Passkey; Defer Hardware FIDO2 Keys | Superseded by 0007 |
| [0003](./0003-cloudnativepg-vs-others.md) | Choose CloudNativePG over alternatives | Accepted |
| [0004](./0004-kyverno-audit-mode.md) | Kyverno verify-signatures starts in Audit, pod-security in Enforce | Accepted |
| [0005](./0005-spire-architecture-local.md) | SPIRE architecture (Local Edition) | Accepted |
| [0006](./0006-keycloak-keys-local.md) | Keycloak Realm Signing Keys (Local Edition) | Accepted |
| [0007](./0007-totp-instead-of-passkeys-locally.md) | TOTP as Primary Factor for Local-Edition Realms; Defer Passkeys/Hardware FIDO2 | Superseded by 0036 |
| [0008](./0008-authz-schema.md) | Authorization Schema — Three-Tier ReBAC (tenant → app → resource) | Accepted |
| [0009](./0009-openbao-seal-strategy.md) | OpenBao Seal Strategy — Two-Instance Transit Auto-Unseal (Local) | Accepted |
| [0010](./0010-istio-ambient-vs-sidecar.md) | Istio Ambient mode (not sidecar); SPIRE as external CA deferred | Accepted (with deferral) |
| [0011](./0011-bff-single-replica-local.md) | BFF runs as a single replica in the local edition | Accepted (local-only scope) |
| [0012](./0012-token-exchange-feasibility.md) | Token-exchange feasibility decision | Accepted — NO-GO (audience-at-login fallback) |
| [0013](./0013-outbound-secrets-no-env.md) | Outbound secrets — no `.env`; OpenBao via SPIFFE-JWT | Accepted |
| [0014](./0014-api-auth-library-design.md) | API auth library design | Accepted |
| [0015](./0015-secret-distribution-pattern.md) | Secret distribution pattern (VSO vs direct-API) | Accepted |
| [0016](./0016-token-and-credential-lifetimes.md) | Token and credential lifetimes | Accepted |
| [0017](./0017-session-expiry-semantics.md) | Session expiry semantics (idle / max / refresh) | Accepted |
| [0018](./0018-multi-tenancy-rls-strategy.md) | Multi-tenancy + Postgres RLS strategy | Accepted |
| [0019](./0019-secret-distribution-interface.md) | Secret distribution interface | Accepted |
| [0020](./0020-openbao-backup-and-dr.md) | OpenBao backup and disaster recovery | Accepted |
| [0021](./0021-git-initialization-and-commit-signing.md) | Git initialization + signed-commit policy | Accepted |
| [0022](./0022-kcadm-admin-long-lived-credential.md) | kcadm-admin long-lived credential carve-out (90-day rotation) | Accepted |
| [0023](./0023-spicedb-datastore-uri-rotation-pattern.md) | SpiceDB datastore_uri rotation pattern (Path B — refresher CronJob) | Accepted |
| [0024](./0024-teleport-community-edition-local.md) | Teleport Community Edition for local; GitHub OAuth pivot | Superseded by 0035 |
| [0025](./0025-jwt-auth-role-token-ttl-rule.md) | JWT auth role `token_ttl` MUST exceed dynamic-credential `default_ttl` | Accepted |
| [0026](./0026-org-defined-custom-roles-rbac-layer.md) | Org-defined custom roles as an RBAC layer on SpiceDB ReBAC | Accepted |
| [0027](./0027-multi-org-membership-and-hierarchy.md) | Multi-organization membership and no-cascade hierarchy | In progress (stub) |
| [0028](./0028-approval-gated-cross-app-workflows.md) | Approval-gated cross-app workflows (pursuit→proposal, proposal→project) | Accepted — proposal→project (award handoff) contract specified; phased build |
| [0029](./0029-per-app-database-strategy.md) | Per-app database strategy — separate DBs with shared UUIDs from control plane | In progress (stub) |
| [0030](./0030-custom-portal-as-sole-admin-ux.md) | Custom portal as sole admin UX; Keycloak default UI never shown to end users | In progress (stub) |
| [0031](./0031-minio-kes-for-sse-rotation.md) | MinIO KES for SSE-S3 key rotation | Superseded (drain-and-rotate; KES kept as fallback) |
| [0032](./0032-istio-gateway-replaces-ingress-nginx.md) | Istio ingress gateway replaces EOL ingress-nginx | Accepted — cutover 2026-06-03 |
| [0033](./0033-trivy-operator-clientserver-mode.md) | Trivy Operator runs in ClientServer mode (built-in trivy-server) | Accepted — applied 2026-06-03 |
| [0034](./0034-stripe-connect-oauth-for-tenant-payments.md) | Stripe Connect (OAuth, Standard accounts) for tenant payments — replaces bring-your-own-keys | Accepted (strategy) — implementation phased |
| [0035](./0035-tailscale-replaces-teleport.md) | Tailscale replaces Teleport for operator access | Accepted (supersedes 0024) |
| [0036](./0036-production-authentication-factors-passkeys.md) | Production authentication factors — passkeys (mandatory for operators, flexible for tenants) | Accepted (supersedes 0007 posture) |
| [0037](./0037-dedicated-document-rendering-service.md) | Dedicated document-rendering service (Gotenberg) | Accepted |
| [0038](./0038-ecosystem-block-document-framework.md) | Ecosystem block-document framework (web · email · PDF · dashboards) | Accepted |
| [0039](./0039-rootless-docker-for-ci-runners.md) | Rootless Docker for the self-hosted CI runners | Accepted |
| [0040](./0040-fleet-ci-reusable-build-and-sudoers-gated-deploy.md) | Fleet CI/CD — reusable build workflow + sudoers-gated one-command deploys | Accepted |
| [0041](./0041-canonical-core-data-spine.md) | Canonical Core Data Spine — People, Clients, Engagements | Accepted |
| [0042](./0042-rls-guc-standard-app-org-id.md) | Fleet RLS session-context standard — `app.org_id` / `app.user_id` | Accepted |
| [0043](./0043-ecosystem-db-shared-package.md) | `@jaupole/ecosystem-db` — shared migration runner, outbox, numbering | Accepted |
| [0044](./0044-physical-db-consolidation.md) | Physical DB consolidation — one `ecosystem-db` cluster, five databases | Accepted |
| [0045](./0045-csp-inline-styles-accepted.md) | Inline-styles CSP keyword accepted fleet-wide (rule-18 deviation) | Accepted |

## Template

When you create a new ADR, use this template. Number sequentially.

```markdown
# ADR-NNNN: <short title>

**Status**: Proposed | Accepted | Superseded by ADR-XXXX | Deprecated
**Date**: YYYY-MM-DD
**Decision-makers**: <who signed off>

## Context

What's the situation? What problem are we trying to solve? What constraints exist?

## Decision

Stated in one or two sentences. The thing we chose.

## Rationale

Why this option over the others? Specific reasoning, ideally with references.

## Alternatives considered and rejected

For each, what was it, what were its pros, what were its cons, why didn't we pick it?

## Consequences

What does this commit us to? What does this preserve? What new risks does this introduce?

## Re-evaluation criteria

Under what conditions should we revisit this decision?

## References

Links to relevant docs, papers, prior art.
```

## Conventions

- ADRs are **append-only**. When a decision changes, write a new ADR that supersedes the old one (and update the old one's Status to "Superseded by ADR-XXXX"). Don't edit history.
- Keep them short. 1-2 pages of plain text maximum. If your ADR is longer, you're probably writing implementation notes — put those somewhere else.
- Link to ADRs from CLAUDE.md and from the architecture docs that depend on them.
