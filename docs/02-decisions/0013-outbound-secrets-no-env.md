# ADR-0013: Outbound secrets — no `.env`; OpenBao via SPIFFE-JWT

**Status**: Planned (Phase 6b-2)
**Date**: TBD
**Decision-makers**: Project owner

## Intended scope

Outbound third-party secrets are fetched from OpenBao at runtime via SPIFFE-JWT auth; banned from `.env`, env vars, ConfigMaps, K8s Secrets, source control.

To be written during Phase 6b-2. Will cover: `apps/lib/secrets/` design, KV-v2 path scheme (Vault Secrets Operator-compatible), templated per-app policy, runtime hygiene (`Secret` type, `Use()`-pattern access, redaction-aware logger), `Hardened` mode rollout plan, multi-layer prevention guardrails (pre-commit + CI + Kyverno + Trivy + self-expiring escape hatch), and the rationale for each defense layer.

## Why this slot exists as a stub

Reserved per the CLAUDE.md ADR-numbering rules so PLAN.md and the Phase 6b-2 prompt doc can reference `ADR-0013` today without a future renumber.

## References

- [Phase 6b-2 prompt (currently bundled in phase-06b-api-pattern.md)](../05-claude-code-prompts/phase-06b-api-pattern.md)
- [PLAN.md — Phase 6b-2 entry](../../PLAN.md)
