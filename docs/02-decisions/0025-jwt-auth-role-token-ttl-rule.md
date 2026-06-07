# ADR-0025: JWT auth role `token_ttl` MUST exceed dynamic-credential `default_ttl`

**Status**: Accepted
**Date**: 2026-05-05
**Decision-makers**: Project owner
**Phase**: Phase 9 retrospective

## Context

The platform uses two OpenBao surfaces in concert:

1. **`auth/jwt`** — workloads with a SPIFFE-JWT-SVID exchange it via `auth/jwt/login` for a BAO_TOKEN scoped to a specific role (one role per workload). The role's `token_ttl` controls how long that BAO_TOKEN lives.
2. **`database/creds/<role>`** — once the workload holds a BAO_TOKEN, it mints short-lived dynamic Postgres credentials. The credential's lifetime is controlled by `default_ttl` on `database/roles/<role>` (and `max_ttl` for explicit-renewal headroom).

OpenBao **binds child leases (the dynamic credential) to the parent token (the BAO_TOKEN)**. When the parent token expires, **all child leases are revoked immediately**, regardless of the credential's own `default_ttl`.

This was discovered the hard way during Phase 9 deployment (2026-05-03/04). The `spicedb-datastore-refresher` JWT auth role had `token_ttl=10m`; the `spicedb-readwrite` database role had `default_ttl=14h`. Each refresher firing minted a fresh credential — and OpenBao revoked it 10 minutes later when the parent token died, even though the credential was supposed to live 14 hours. SpiceDB then crash-looped on `28P01` SASL auth failures for the rest of every cycle, in turn taking down `authzen-facade` (its sole client), in turn breaking every authorization decision in the platform. See [Phase 9 retrospective § "SpiceDB orphan-lease bug"](../99-archive/05-claude-code-prompts/phase-09-retrospective.md#spicedb-orphan-lease-bug-the-big-one) for the full incident write-up.

The same shape exists for any first-class app that uses `apps/lib/secrets/` to mint dynamic Postgres credentials at request time. `helloworld-backend` had the same defect — caught the same week, same root cause.

## Decision

**Every `auth/jwt/role/<workload>` that is used (directly or transitively) to mint dynamic credentials MUST set `token_ttl` strictly greater than the longest `default_ttl` of any database (or other dynamic-secrets-engine) role the workload's policy grants `read` on. Headroom: at least 1 hour.**

Concretely:

```
token_ttl  >  max(default_ttl across reachable database/roles/*)  +  ≥1h headroom
```

`token_max_ttl` should be set equal to `token_ttl` unless the workload explicitly renews — none of our workloads renew today, so the two are kept identical.

The rule is enforced at JWT-auth-role bootstrap time. There is no admission-controller layer that could enforce it at apply time today — it lives in the bootstrap script's invariant comments and in this ADR.

## Rationale

### Why the rule is `token_ttl > credential default_ttl` and not `≥`

`>` (strict) gives the credential its full intended lifespan. If `token_ttl == default_ttl`, the credential and the parent token expire at the same instant — there is a brief race where the credential is alive on the Postgres side but the workload can no longer present a valid BAO_TOKEN to renew anything. The 1h headroom keeps that race off the table and gives the workload time to react to a 28P01 by re-authenticating cleanly.

### Why not "set `token_ttl` very long and forget it"

Long-lived BAO_TOKENs erode the security benefit of SPIFFE-JWT-SVID auth. A token leaked from a pod's filesystem is replayable for `token_ttl` minutes. The compensating control is **the SPIFFE-ID binding, not the token lifetime** — `auth/jwt/role/<workload>` is `bound_subject="spiffe://secforge.local/ns/<ns>/sa/<sa>"`, so a leaked token is only useful from that exact pod identity. Within that constraint, longer `token_ttl` is a continuity benefit, not a security regression.

The trap operators are tempted by is **shortening `token_ttl` "for security"**. Don't. It revokes the credentials the workload depends on. The boundary is the SPIFFE-ID, not the clock.

### Why this isn't enforced by Kyverno

A future Kyverno policy could lint the bootstrap scripts (regex `token_ttl=([0-9]+)([hms])` and compare against the corresponding `default_ttl=`), but the relationship between an auth/jwt role and the database roles it can reach goes through a Vault policy file — Kyverno doesn't read those. Until we add a script-side linter, the rule is enforced by code review against the comment block in the bootstrap script.

## Where this is enforced today

Two scripts encode this rule explicitly. Both have comment blocks pointing to this ADR; treat each as a precedent for any new JWT auth role:

- [`infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh`](../../infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh) — `spicedb-datastore-refresher` role: `token_ttl=15h`, `database/roles/spicedb-readwrite default_ttl=14h`.
- [`infrastructure/helloworld/provision-db-and-bao.sh:189`](../../infrastructure/helloworld/provision-db-and-bao.sh#L189) — `helloworld-backend` role: `token_ttl=90m`, `database/roles/helloworld-backend-readwrite default_ttl=1h`.

## Alternatives considered and rejected

### (A) Set every `token_ttl` to a flat platform-wide ceiling (e.g. 24h)

Simplest mental model. Rejected because `token_ttl` should track the credential's lifetime — pinning everything to 24h grants more replay surface than the underlying credential needs. Workloads with `default_ttl=1h` (helloworld-backend) would have a 24× longer token-replay window than necessary.

### (B) Have workloads explicitly renew their credential leases via `bao lease renew`

This would decouple `token_ttl` from credential lifetime — the workload could keep extending the credential as long as it kept a valid token. Rejected because:
- Off-the-shelf workloads (SpiceDB) cannot be modified to call `bao lease renew`.
- For first-class apps using `apps/lib/secrets/`, adding renewal logic doubles the surface of the library and the failure modes (renewal-fail vs initial-mint-fail are different recovery paths). The simpler pattern is "mint a new credential when the old one expires" — which is what the library already does on 28P01.

### (C) Drop dynamic credentials and use static Postgres passwords from KV

Trivially makes the problem disappear. Rejected — defeats the purpose of OpenBao's database engine and is exactly the anti-pattern ADR-0013 + ADR-0015 push us away from.

## Consequences

### Operational

- New JWT auth roles must compute `max(default_ttl)` over the database roles the workload can reach (via its OpenBao policy) before choosing a `token_ttl`. This is mostly trivial — most workloads reach exactly one `database/roles/*`.
- Operator-time auditing: at the next rotation review, walk every `auth/jwt/role/*` and confirm the relationship still holds. If a `default_ttl` is bumped without the corresponding `token_ttl` bump, the cluster wedges silently between cron firings.

### Security

- No regression vs the pre-Phase-9 implicit pattern (which had the same SPIFFE-ID binding). The only thing that changes is the `token_ttl` number.
- A leaked BAO_TOKEN is replayable for `token_ttl` minutes from the bound SPIFFE-ID only. With `token_ttl` in the 1h–15h range across our workloads, this is materially shorter than a long-lived static credential and is bounded by the workload identity, not just the token bytes.

### Future work

- **Script-side linter.** A pre-commit hook that reads each bootstrap script, extracts `token_ttl=` and the matching `default_ttl=` from the role-creation block, and fails on `token_ttl ≤ default_ttl`. Cheap to write; not yet written.
- **Phase 10 cross-check.** Phase 10's outbound-secrets step (`10.{N}.5`) must include this rule in its review checklist. The Phase 10 prompt has been amended to call it out.

## Re-evaluation criteria

Revisit if either of:

- OpenBao changes its lease-binding semantics (e.g., a future release decouples child-lease lifetime from parent-token lifetime). Watch the upstream changelog.
- A workload pattern emerges that needs a `token_ttl` shorter than the credential `default_ttl` — none today, but if one shows up, this ADR's rule needs an explicit carve-out (probably "workloads that call `apps/lib/secrets/` re-fetch on 28P01 and thus tolerate parent-token-driven revocation").

## References

- [Phase 9 retrospective § "SpiceDB orphan-lease bug"](../99-archive/05-claude-code-prompts/phase-09-retrospective.md#spicedb-orphan-lease-bug-the-big-one) — the precipitating incident.
- [ADR-0013 — Outbound secrets: no `.env`](./0013-outbound-secrets-no-env.md) — the broader pattern this rule supports.
- [ADR-0015 — Secret distribution pattern](./0015-secret-distribution-pattern.md) — VSO vs direct-API split that frames where this rule applies.
- [ADR-0023 — SpiceDB `datastore_uri` rotation pattern](./0023-spicedb-datastore-uri-rotation-pattern.md) — adjacent context (SpiceDB-specific refresher CronJob; the lease-vs-token confusion was first amended there 2026-05-03).
- [`infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh`](../../infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh) — rule enforced for `spicedb-datastore-refresher`.
- [`infrastructure/helloworld/provision-db-and-bao.sh`](../../infrastructure/helloworld/provision-db-and-bao.sh) — rule enforced for `helloworld-backend`.
