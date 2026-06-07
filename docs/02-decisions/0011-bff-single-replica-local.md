# ADR-0011: BFF runs as a single replica in the local edition; per-session DPoP keys are the unblocker for HA

**Status**: Accepted (with explicit local-only scope)
**Date**: 2026-04-29
**Decision-makers**: Project owner

## Context

Phase 6.6 implements the helloworld-bff per the contract in [docs/01-architecture/04-bff-pattern.md](../01-architecture/04-bff-pattern.md). The phase prompt asks for `replicas: 2` for HA. A subtler constraint cuts against that:

DPoP (RFC 9449) binds an issued access token to a public key via the `cnf.jkt` thumbprint. Every upstream call needs a fresh DPoP proof JWT signed by the corresponding private key. The BFF therefore holds a private key in process; that key is what the issued access tokens trust.

Phase 6.5 settled the keypair as **per-pod ECDSA P-256, generated in `main()`, in-memory only**. With two replicas, one pod's private key cannot mint valid DPoP proofs for access tokens issued under the other pod's jkt. Consequences with `replicas: 2`:

- Either every browser session needs sticky routing to the pod that issued its tokens (lose HA on pod restart anyway; require ingress-side stickiness), or
- All replicas share a keypair (a long-lived in-cluster secret materially weakens DPoP's compromised-pod blast radius), or
- Each session has its own keypair persisted somewhere both replicas can read (per-session DPoP keys in Valkey, encrypted at rest with a KEK from OpenBao Transit).

The third option is the production-correct answer. It is also a real implementation: ECDSA-key serialization to PKCS#8, Transit `encrypt`/`decrypt` on each cross-pod handover, key-rotation story for the KEK. Cost: about a day of focused work plus ongoing Transit calls per upstream request.

In the local edition there are no real users, no on-call rotation, and pod restart is rare. The cost of `replicas: 2` is real; the benefit is theatrical.

## Decision

The local-edition helloworld-bff Deployment ships with **`replicas: 1`** in Phase 6.6 / 6.8. HPA is not enabled.

The cloud edition will use **per-session DPoP keys persisted in Valkey, encrypted at rest with an OpenBao Transit KEK**, which removes the per-pod constraint and enables `replicas: ≥ 2` plus HPA.

## Rationale

- **Per-pod DPoP keys + single replica is the simplest design that is correct.** Every other option here either weakens DPoP's security properties (shared in-cluster keypair, sticky-session stand-ins) or front-loads a non-trivial cryptographic-storage feature for a workload that has no users.
- **The local-edition has no HA goal.** The platform mission ([CLAUDE.md](../../CLAUDE.md)) is iterating on the application layer before committing to a cloud destination. Pod-level HA does not appear in any local-edition success criterion.
- **Pod restart is acceptable.** The BFF detects a stale `dpop_jkt_at_issue` in a session on the first post-restart upstream call and forces a refresh-token exchange (refresh tokens are deliberately NOT DPoP-bound at Keycloak; see Phase 6.5 design doc). One extra round-trip on first request after a pod restart, transparent to the user.
- **Flag-driven divergence kept narrow.** The same code paths run in both editions. The cloud-only addition is a `BFF_DPOP_KEY_STORE=valkey-per-session` env-var-toggled implementation; local stays on the in-memory default.

## Alternatives considered and rejected

### Sticky sessions via session-cookie hash

Pros: keeps per-pod keys; no shared key material; nominally HA across pod failures (if multi-node).
Cons: any pod restart kills the sessions on that pod (cookie hash still maps there). On Docker Desktop's single-node cluster the failure mode is identical to single-replica anyway. In cloud, sticky routing has well-known drawbacks (uneven load; rolling-restart session loss). Not worth the ingress-config complexity for the same effective availability.

### Shared in-cluster DPoP keypair across replicas

Pros: trivially supports `replicas: 2`.
Cons: a single private key shared via K8s Secret, mounted into every BFF pod. Compromise of any BFF pod yields the key for all DPoP-bound tokens platform-wide. The DPoP threat model is "attacker steals an access token from the wire (or proxy log, or browser cache)"; a shared in-cluster key restores that exact replay capability for any insider with cluster access. Defeats the purpose of DPoP.

### Per-session DPoP keys in Valkey, encrypted with OpenBao Transit, in 6.6

Pros: production-correct; supports `replicas: ≥ 2` cleanly.
Cons: roughly a day of focused implementation (PKCS#8 serialization round-trip, Transit `encrypt`/`decrypt` calls per upstream request, KEK rotation story, structured handling of decrypt failures). All of that work goes into a single-user development environment. Better to do it once at pre-migration time when there are concrete HA / load goals to justify it.

### Drop DPoP entirely; rely on Bearer + mTLS only

Pros: no per-key constraints; trivially HA.
Cons: gives up DPoP's bound-token property. CLAUDE.md prohibits OAuth-2.0-style flows; the platform has committed to OAuth 2.1 with DPoP. Non-starter.

## Consequences

**Commits us to**:
- Single-replica BFF until pre-migration hardening enables per-session DPoP keys.
- A `BFF_DPOP_KEY_STORE` env-var-style switch in `dpop.go` that defaults to in-memory and accepts a future `valkey-per-session` value.
- Documentation calling out that "BFF crash = brief window of refresh required" is normal local behaviour.

**Preserves**:
- Per-pod DPoP key isolation; an attacker who compromises one BFF pod gets that pod's key, not a cross-replica key.
- Backend validation logic ([04-bff-pattern.md §"Backend API authentication contract"](../01-architecture/04-bff-pattern.md)) is unchanged when the cloud edition switches to per-session keys — the wire shape stays identical.

**New risks**:
- A BFF pod crash temporarily breaks all in-flight upstream requests (until refresh completes). Acceptable locally; tracked as a Phase pre-migration follow-up in PLAN.md.
- Anyone reading PLAN.md or the BFF Deployment manifest must recognise that `replicas: 1` is intentional and not "TODO bump to 2." This ADR is the canonical answer when that question comes up.

## Re-evaluation criteria

Revisit if any of these become true:

- The local edition gains real users (not just the project owner).
- The phase prompt for any local-edition app starts depending on cross-replica BFF behaviour.
- Pre-migration hardening begins — at that point this ADR drives the per-session-DPoP-keys-in-Valkey work.
- A future BFF feature (long-running websocket, pinned upstream connection) makes pod-restart-equals-refresh-token-exchange unacceptable UX.

## References

- [docs/01-architecture/04-bff-pattern.md](../01-architecture/04-bff-pattern.md) — BFF pattern design, including the "Replica strategy in Phase 6 (local)" section that references this ADR.
- [docs/99-archive/05-claude-code-prompts/phase-06-istio-bff.md](../99-archive/05-claude-code-prompts/phase-06-istio-bff.md) — Phase 6.8 spec from which this deviates.
- [PLAN.md](../../PLAN.md) — Phase 6 follow-up tracking the pre-migration cloud cutover to per-session keys.
- [RFC 9449 — DPoP](https://datatracker.ietf.org/doc/html/rfc9449)
