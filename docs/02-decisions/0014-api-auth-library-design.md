# ADR-0014: API auth library design

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

[ADR-0012](./0012-token-exchange-feasibility.md) closed the question of *how* the BFF mints tokens for downstream APIs (NO-GO on RFC 8693 token-exchange; pivot to audience-at-login). What it left open were the four design questions in its [§"Open design questions"](./0012-token-exchange-feasibility.md#open-design-questions-resolve-at-start-of-phase-6b-1) — the answers to which determine the shape of `apps/lib/api-auth/`, the Go library that every SecForge BFF + backend API consumes for inbound auth, outbound token minting, and audit logging.

This ADR records the four answers (settled in a 2026-05-01 design conversation) and the library API contract those answers commit us to. Phase 6b-1 implements the library against this contract.

This ADR was originally a stub claiming the slot per the CLAUDE.md ADR-numbering rule. The stub anticipated being filled if Phase 6b-1's design surfaced decisions worth recording. It did; this ADR replaces the stub.

## Decision summary

The four answers (full text in [ADR-0012 § Resolution](./0012-token-exchange-feasibility.md#resolution-2026-05-01)):

| ID | Question | Decision |
|---|---|---|
| Q1 | Audience set scope | **Per-app BFF.** Four separate BFF deployments + Keycloak clients with non-overlapping audience scopes. No shared BFF. |
| Q2 | Audience discovery | **Static config in BFF.** `BFF_AUDIENCE_LIST` env var; adding a downstream API is a documented two-step PR'd operator workflow. No dynamic service-registry discovery. |
| Q3 | Refresh-token flow on audience change | **Try-expand-fallback-relogin.** Library requests refresh with expanded scope; if Keycloak rejects, library returns 401 + clear-session cookie and BFF redirects to `/login`. |
| Q4 | Audit-log actor reconstruction | **SPIFFE + request-id schema.** Each hop emits a structured log line carrying `request_id`, `hop_index`, `caller_workload_id` (SPIFFE-SVID), `caller_user_sub`, `target_audience`, `timestamp`, `endpoint`, `status`. Reconstruction via `{request_id="..."}` Loki query. |

## Library API surface

`apps/lib/api-auth/` exposes three primary types. Go interfaces only — implementation is Phase 6b-1's job.

```go
// Middleware — used by BFFs (and any API that accepts user-tier tokens)
// to validate inbound requests.
type Middleware struct { /* ... */ }

func (m *Middleware) ValidateInbound(req *http.Request) (*Claims, error)
```

`ValidateInbound` parses the `Authorization: Bearer <jwt>` header on an inbound request, verifies the JWT signature against Keycloak's JWKS (cached locally with refresh on `kid` miss), validates `iss`, `aud` (against the Middleware's configured audience set — narrowed to "what this service actually accepts"), `exp`, `nbf`, and `iat`. **It also validates the DPoP proof** in the `DPoP` header against the JWT's `cnf.jkt`: same JWT replayed without the matching DPoP proof is rejected. On success returns a `*Claims` carrying `sub`, `aud`, `realm_access.roles`, the SPIFFE-SVID of the caller (extracted from the mTLS peer cert if present, else nil), and the `cnf.jkt` thumbprint. On failure returns a typed error (`ErrInvalidToken`, `ErrAudienceMismatch`, `ErrDPoPMissing`, `ErrDPoPMismatch`, `ErrTokenExpired`) so callers can translate to the right HTTP status. **Does not** authorize the request — that's the caller's `SpiceDB CheckPermission` call.

```go
// Client — used by the BFF (and by any service that mints outbound tokens
// to call another API in the same trust domain) to obtain a downstream-API-
// scoped token from the user's session.
type Client struct { /* ... */ }

func (c *Client) MintTokenForAudience(ctx context.Context, aud string) (string, error)
```

`MintTokenForAudience` returns a JWT bound to the BFF's per-pod ECDSA DPoP key, with the user's session as the subject and the requested `aud` as the target. Implementation:

1. Look up the user's session in Valkey (the BFF's session store from Phase 6).
2. If the session's cached access token has the requested `aud` and is not within 30 s of expiry → return it.
3. Otherwise, refresh the user's tokens at Keycloak with the expanded `scope` parameter that includes the new audience. **This is the Q3 fallback path:**
   - On success → cache the new token, return it.
   - On rejection (`invalid_scope`, `invalid_grant`, etc.) → return `ErrAudienceUnavailable`. The BFF's HTTP handler translates that into a 401 with a session-clearing `Set-Cookie` and a `Location: /login`.
4. If `aud` is not in the BFF's `BFF_AUDIENCE_LIST` config at all → return `ErrAudienceNotConfigured` immediately, never touch Keycloak. (Per Q2: the static config is the source of truth.)

**Does not** mint per-call minimum-scope tokens (audience-at-login model — see ADR-0012). **Does not** call the RFC 8693 token-exchange endpoint (NO-GO per ADR-0012).

```go
// Audit — used by every service in the call chain to emit a structured
// log line per hop. Schema enforced at compile time via the typed function
// signature; missing fields fail at the call site, not at log-aggregation
// time.
type Audit struct { /* ... */ }

func (a *Audit) LogHop(req *http.Request, hopIndex int, callerWorkloadID, callerUserSub, targetAudience string, status int) error
```

`LogHop` emits a single JSON log line to STDOUT (Promtail picks it up to Loki) with the fields specified in [ADR-0012 § Q4 Resolution](./0012-token-exchange-feasibility.md#q4--audit-log-actor-reconstruction-spiffe-request-id-schema): `request_id` (extracted from `X-Request-ID`; generated if absent and forwarded via response header so the next hop sees the same value), `hop_index`, `caller_workload_id`, `caller_user_sub`, `target_audience`, `timestamp` (ISO8601 ms), `endpoint` (HTTP method + path from `req`), `status`. Field order is fixed by the schema doc. **Does not** authorize, validate, or modify the request — just logs.

## Per-API audience validation contract

Backend services consume `Middleware` and configure it with a single allowed audience: their own service identifier (e.g., `api.proposal-forge.svc`). `ValidateInbound` rejects any token whose `aud` does not contain that audience. This is the contract that makes Q1's per-app BFF design enforceable: a token minted for `api.proposal-forge.svc` cannot be replayed against `api.project-tracker.svc`, even if both audiences are in some BFF's request — because each backend independently rejects audiences that aren't theirs.

Backends MUST NOT skip audience validation, MUST NOT accept multiple audiences from a single Middleware instance (configure separate Middlewares for separate accept-paths), and MUST NOT extract the audience from the request to "see what the caller wanted" — the audience comes from the Middleware's config, not the inbound token.

## DPoP binding contract

Every token minted by `Client.MintTokenForAudience` is bound to the BFF's per-pod ECDSA P-256 key (the same DPoP key from Phase 6's BFF design — [ADR-0011](./0011-bff-single-replica-local.md) constrains this to a per-pod, in-memory, never-rotated-during-pod-life key). Keycloak's DPoP feature ([already enabled per Phase 3](../01-architecture/01-iam-platform.md)) emits the `cnf.jkt` claim in the access token bound to the JWS thumbprint of that key.

`Middleware.ValidateInbound` requires a matching `DPoP` proof header on every protected request: a fresh JWS over the request's HTTP method + URL + access token thumbprint, signed by the same key. Replay without the key is rejected. Keys are not portable across BFF pods; if a BFF is rolled mid-session, the user's next request fails DPoP validation and the library issues the same 401 + session-clear behavior as the Q3 fallback. (Phase 6 already accepted this single-replica constraint for the local edition; cloud edition revisits with a shared-DPoP-key strategy.)

## Error-handling contract

Failures from `Middleware.ValidateInbound` and `Client.MintTokenForAudience` are typed Go errors. Mapping to HTTP responses is the caller's job, but the library documents the canonical mapping:

| Library error | HTTP | What the caller does |
|---|---|---|
| `ErrInvalidToken` | 401 | Reject; do not retry |
| `ErrTokenExpired` | 401 | Reject; client should refresh |
| `ErrAudienceMismatch` | 401 | Reject; suggests caller used a token for the wrong service |
| `ErrDPoPMissing` | 401 | Reject; client should retry with a DPoP proof |
| `ErrDPoPMismatch` | 401 | Reject; suggests pod roll or replay attempt |
| `ErrAudienceNotConfigured` | 500 | The BFF's own config is wrong; alert + fail loud |
| `ErrAudienceUnavailable` | 401 + Set-Cookie clearing session + Location: /login | Q3 fallback path; user re-logs in |
| `ErrKeycloakUnreachable` | 502 | Transient; safe to retry |

`ValidateInbound` and `MintTokenForAudience` MUST NOT panic on any input; all paths must return a typed error.

## Out of scope

- **Token-exchange (RFC 8693).** [ADR-0012 NO-GO](./0012-token-exchange-feasibility.md#decision). The library has no `ExchangeFor` function.
- **Per-call minimum-scope minting.** Tokens carry the BFF's full configured audience set; downstream APIs narrow at validation time, not minting time.
- **A→B→C call chains where C must verify B's authority independently of A.** Audience-at-login produces a token whose `sub` is the original user; B and C see the same `sub` and the same `aud` set. C cannot tell whether A or B was the immediate caller from the token alone — it can only see this from the audit log's `hop_index` and `caller_workload_id`. If a future Phase needs cryptographic non-repudiation of the *immediate* caller, that is one of the watching-brief triggers in [ADR-0012 § Re-evaluation criteria](./0012-token-exchange-feasibility.md#re-evaluation-criteria).
- **Service-registry-driven audience discovery.** [Q2 NO](#decision-summary). Library reads audience set from caller-supplied config; does not poll any registry.
- **Implementation.** Phase 6b-1 builds the library against this ADR; this ADR is the contract, not the code.

## Relationship to other ADRs

- [ADR-0011 — BFF single replica in local edition](./0011-bff-single-replica-local.md): the per-pod DPoP key constraint that this library inherits.
- [ADR-0012 — Token-exchange feasibility](./0012-token-exchange-feasibility.md): the NO-GO that drives this library's audience-at-login model + the four open questions this ADR resolves.
- [ADR-0013 — Outbound secrets: no env vars](./0013-outbound-secrets-no-env.md): how the BFF reads its `BFF_AUDIENCE_LIST` and Keycloak client credentials. The library does not handle secret loading; it accepts already-loaded values.
- [ADR-0015 — Secret distribution pattern](./0015-secret-distribution-pattern.md): the VSO/direct-API split that backs the Middleware's JWKS cache and the Client's session store.

## References

- [Phase 6b-1 prompt](../05-claude-code-prompts/phase-06b-api-pattern.md) — implements this ADR
- [Architecture: API pattern](../01-architecture/06-api-pattern.md) — narrative description of the audience-at-login model
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693) — what we did NOT use
- [RFC 9449 — OAuth 2.0 Demonstrating Proof of Possession (DPoP)](https://datatracker.ietf.org/doc/html/rfc9449) — what we DID use, for sender-constraining
- [SPIFFE SVID — JWT-SVID format](https://github.com/spiffe/spiffe/blob/main/standards/JWT-SVID.md) — the workload identity format used in `caller_workload_id`
