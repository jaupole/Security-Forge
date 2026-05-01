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
| [0007](./0007-totp-instead-of-passkeys-locally.md) | TOTP as Primary Factor for Local-Edition Realms; Defer Passkeys/Hardware FIDO2 | Accepted |
| [0008](./0008-authz-schema.md) | Authorization Schema — Three-Tier ReBAC (tenant → app → resource) | Accepted |
| [0009](./0009-openbao-seal-strategy.md) | OpenBao Seal Strategy — Two-Instance Transit Auto-Unseal (Local) | Accepted |
| [0010](./0010-istio-ambient-vs-sidecar.md) | Istio Ambient mode (not sidecar); SPIRE as external CA deferred | Accepted (with deferral) |
| [0011](./0011-bff-single-replica-local.md) | BFF runs as a single replica in the local edition | Accepted (local-only scope) |
| [0012](./0012-token-exchange-feasibility.md) | Token-exchange feasibility decision | Accepted — NO-GO (audience-at-login fallback) |
| [0013](./0013-outbound-secrets-no-env.md) | Outbound secrets — no `.env`; OpenBao via SPIFFE-JWT | Planned (Phase 6b-2) |
| [0014](./0014-api-auth-library-design.md) | API auth library design | Planned (Phase 6b-1, may be deleted if redundant with 0012) |

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
