# API auth pattern — audience-at-login + DPoP + per-hop audit

> **Implements:** [ADR-0014](../02-decisions/0014-api-auth-library-design.md). **Replaces:** the rejected RFC 8693 token-exchange pattern from [ADR-0012](../02-decisions/0012-token-exchange-feasibility.md). **Library:** [`apps/lib/api-auth/`](../../apps/lib/api-auth) (Phase 6b-1). **Runbook:** [`docs/03-runbooks/api-auth-library.md`](../03-runbooks/api-auth-library.md).
>
> **Audience:** anyone designing a new SecForge backend or BFF. The narrative below explains *why* the library's surface looks the way it does so reviewers can evaluate a proposed deviation against the trade-offs that landed it here.

---

## The problem this pattern solves

A SecForge user logs in via the BFF and the BFF holds the user's session. Backend API calls flow `browser → BFF → backend`. The backend needs to know:

1. **Who** the user is (the `sub` claim).
2. **What audience** the token was minted for — the backend rejects tokens minted for a different service even if the signature verifies (cross-API replay defense).
3. **Whether the token holder still possesses the key** that bound the token — this is DPoP's proof-of-possession property, defending against bearer-token theft.
4. **Which hop** in the chain produced this request — for audit-trail reconstruction when something goes wrong.

The pattern below covers (1)-(4) without using RFC 8693 token-exchange (which Phase 6b-0 NO-GO'd) and without per-call minimum-scope minting (which would multiply Keycloak load and create cache-coherency issues).

---

## The four design decisions (ADR-0012 § Resolution + ADR-0014)

| Q | Question | Decision |
|---|---|---|
| Q1 | Audience set scope | **Per-app BFF.** Four BFF deployments + Keycloak clients with non-overlapping audience scopes. |
| Q2 | Audience discovery | **Static config in BFF.** `BFF_AUDIENCE_LIST` env var; runtime cannot bypass. |
| Q3 | Refresh-token flow on audience change | **Try-expand-fallback-relogin.** Refresh with expanded `scope`; if Keycloak rejects, 401 + clear-session + `Location: /login`. |
| Q4 | Audit-log actor reconstruction | **SPIFFE + request-id schema.** Each hop emits `request_id`, `hop_index`, `caller_workload_id`, `caller_user_sub`, `target_audience`, `timestamp`, `endpoint`, `status`. |

The decisions cluster around one principle: **the BFF's static config is the source of truth for what audiences exist; Keycloak is the issuer of audience-bearing tokens; backends are independent enforcers of their own audience.**

---

## Token shape and lifecycle

### When the user logs in (Phase 6 BFF flow)

```
[Browser] ──OIDC code+PKCE+PAR──▶ [BFF] ──private_key_jwt──▶ [Keycloak]
                                                              ◀── id_token
                                                              ◀── access_token (cnf.jkt = BFF's per-pod ECDSA-P256 thumbprint)
                                                              ◀── refresh_token
[BFF] persists session → Valkey
[BFF] sets HttpOnly+Secure cookie → [Browser]
```

The access token Keycloak issues already carries `cnf.jkt` because the BFF sent a DPoP header on the token endpoint. The token's `aud` is whatever Keycloak's client-scope mapping resolves at login time — typically the BFF's own ID plus any **default** audience scopes mapped on the client.

### When the BFF needs a different audience

```
[BFF.proxy] ──Client.MintTokenForAudience(ctx, "backend-a")──▶ [apps/lib/api-auth Client]
   1. Is "backend-a" in BFF_AUDIENCE_LIST?  NO  → ErrAudienceNotConfigured (500; loud)
                                            YES → continue
   2. Is the cached access_token's aud already includes "backend-a" AND
      ExpiresAt > now+30s?                  YES → return cached
                                            NO  → continue
   3. POST /token with grant_type=refresh_token + private_key_jwt + DPoP
      proof + scope=<existing> + "backend-a"
        Keycloak issues new access_token with aud including "backend-a"
            → cache + return
        Keycloak rejects (invalid_scope, etc.)
            → ErrAudienceUnavailable → BFF clears session + redirects /login
```

The library does **not** mint per-call minimum-scope tokens. The token returned carries the BFF's full configured audience set; downstream backends narrow at validation time, not minting time. This trades some token-size growth (negligible at platform scale) for dramatically simpler caching and zero audience-discovery flow.

### When a backend receives the token

The backend wraps every protected route with `Middleware.Wrap`, which calls `ValidateInbound` and on success attaches the validated `*Claims` to the request context:

```
[BFF] ──HTTP + DPoP-bound JWT──▶ [Backend Middleware.ValidateInbound]
   1-3.  Parse + verify JWT signature against Keycloak JWKS (cached)
   4-8.  iss / aud / exp / nbf / iat — aud must contain ExpectedAudience
   9-16. DPoP proof present + signature + htm + htu + iat + jti + cnf.jkt
   17.   Atomic insert jti into replay cache (90s TTL)
   → *Claims attached to context
[Backend handler] runs business logic, calls SpiceDB CheckPermission
[Backend handler] returns response
[Middleware] emits Audit.LogHop(hop_index=2 from this backend's perspective)
```

The 17-step chain is in [ADR-0014 § Library API surface](../02-decisions/0014-api-auth-library-design.md#library-api-surface) and the runbook. Each step short-circuits to a typed error. The mapping from typed error to HTTP status is the caller's job — the library never writes a response.

---

## Why audience-at-login (and not RFC 8693)

The audience-at-login model trades flexibility for reliability:

- **Audience set is determined at login** by Keycloak's client-scope configuration. The BFF requests `scope=openid profile email backend-a backend-b` at login or at the next refresh; Keycloak's client-scope mappers stamp `aud` accordingly.
- **Fewer Keycloak round-trips per request.** A backend call uses a cached token if the audience is already covered; a refresh only fires when the user's current token doesn't carry the target audience.
- **No per-call subject-token marshaling.** RFC 8693's `subject_token` and `actor_token` machinery introduces ordering bugs (which token represents which actor in a chain?), and Keycloak 26.x's preview-feature implementation has known runtime gating issues per the Phase 6b-0 spike findings.
- **One static-config place to add a new downstream audience.** Adding `backend-c` is a 2-step PR to (a) `BFF_AUDIENCE_LIST` in the deployment, and (b) a Keycloak client-scope mapper for the BFF client. The BFF picks it up on next refresh.

The trade-off is that **A→B→C call chains where C must verify B's authority independently of A** are NOT expressible in this model — both the BFF (A) and any downstream (B) hop produce tokens whose `sub` is the original user. C cannot tell whether A or B was the immediate caller from the token alone — it can only see this from the audit log's `hop_index` and `caller_workload_id`. If a future Phase needs cryptographic non-repudiation of the *immediate* caller, that's a watching-brief trigger in [ADR-0012 § Re-evaluation criteria](../02-decisions/0012-token-exchange-feasibility.md#re-evaluation-criteria) and re-spikes RFC 8693.

---

## Per-hop audit log — what makes it reconstructable

The library's `Audit.LogHop` emits one structured-JSON line per call-chain hop. The schema (fixed by [ADR-0012 § Q4 Resolution](../02-decisions/0012-token-exchange-feasibility.md#resolution-2026-05-01)):

```json
{
  "request_id":         "ULID-or-equivalent",
  "hop_index":          1,
  "caller_workload_id": "spiffe://secforge.local/ns/<ns>/sa/<sa>",
  "caller_user_sub":    "user-1",
  "target_audience":    "backend-a",
  "timestamp":          "2026-05-01T12:34:56.789Z",
  "endpoint":           "GET /api/orders",
  "status":             200
}
```

A Loki query `{namespace="app"} |= "<request_id>"` returns every hop in the chain. Sorted by `hop_index`, the chain reconstructs:

```
hop=1  workload=helloworld-bff   user=user-1   target=backend-a   GET /orders → 200
hop=2  workload=helloworld-bff   user=user-1   target=backend-a   GET /orders → 0   (outbound attempt)
hop=2  workload=helloworld-bff   user=user-1   target=backend-a   GET /orders → 200 (outbound result)
hop=3  workload=backend-a        user=user-1   target=backend-b   GET /downstream → 200
```

Note `caller_workload_id` is the WORKLOAD that originated *this* hop — the BFF, not the user. `caller_user_sub` is the user's identity and stays constant across the chain. This intentionally makes the workload-vs-user distinction grep-able at audit time.

---

## DPoP key model

Per [ADR-0011](./bff-pattern.md), the BFF holds **per-pod, in-memory, never-rotated-during-pod-life** ECDSA P-256 DPoP keys. The local edition's single-replica BFF simplifies this; cloud edition revisits with per-session keys persisted in Valkey + Transit-encrypted-at-rest.

A BFF pod roll invalidates every active session's `cnf.jkt`. The library handles this transparently:

1. User's next request hits the new pod.
2. `Client.MintTokenForAudience` checks the cached SessionTokens.
3. The `bffSessionAdapter` notices `sv.DPoPJktAtIssue != currentJKT` and returns `Audiences=[]`, forcing the cache-hit check to fail.
4. Refresh-with-expanded-scope fires; Keycloak issues a new `cnf.jkt`-bound token with the new pod's thumbprint.
5. Request proceeds.

The user does not see this. **Operators see it as a brief spike in Keycloak `/token` traffic after a BFF roll** — that's expected and not pathological.

---

## When the pattern doesn't apply

- **Service-to-service (M2M) without a user.** RFC 8693 client_credentials with `private_key_jwt` is the right primitive there. The library does not implement this in Phase 6b-1 because no in-cluster service needs it; if Phase 7d adds one, extend the library's surface (open an ADR amendment first).
- **Public API tokens issued to external callers.** That's a separate Tier 5 (per ADR-0014's out-of-scope list) — separate Keycloak client per integration, separate library.
- **Webhooks from third parties.** SPIFFE-SVID auth from `apps/security-events-collector/` (Phase 6b-2) is the pattern there.

---

## Cross-references

- [ADR-0011 — BFF single replica in local edition](../02-decisions/0011-bff-single-replica-local.md) — the per-pod DPoP key constraint.
- [ADR-0012 — Token-exchange feasibility](../02-decisions/0012-token-exchange-feasibility.md) — the NO-GO that drives the audience-at-login model + the Q1-Q4 design questions this pattern resolves.
- [ADR-0014 — API auth library design](../02-decisions/0014-api-auth-library-design.md) — the implementation contract.
- [ADR-0017 — Session expiry semantics](../02-decisions/0017-session-expiry-semantics.md) — the Valkey TTL + cookie semantics this pattern relies on.
- [`docs/06-reference/dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md) — the canonical `htu` rule the 17-step chain consumes.
- [`apps/lib/api-auth/`](../../apps/lib/api-auth) — the implementation.
- [`docs/03-runbooks/api-auth-library.md`](../03-runbooks/api-auth-library.md) — usage runbook for new backends + BFFs.
