# Runbook: `apps/lib/api-auth` library

> **Audience:** every backend service author in Phase 9+ + every BFF author in Phase 10+. The library is the canonical implementation of the SecForge audience-at-login + DPoP + per-hop audit pattern.
>
> **Spec:** [ADR-0014](../02-decisions/0014-api-auth-library-design.md) is the contract — file an issue if your reading of this doc and ADR-0014 disagree.
>
> **Built by:** Phase 6b-1 (six commits — see `git log fix-after-07-complete..HEAD --grep=phase-6b-1`).

---

## What this library is

`apps/lib/api-auth/` exposes three primary types:

| Type | Used by | Wraps |
|---|---|---|
| `Middleware` | every backend that accepts user-tier Bearer tokens | inbound JWT signature + claim + DPoP-binding validation against Keycloak's JWKS |
| `Client` | every BFF that mints downstream-API tokens | outbound audience-at-login refresh-with-expanded-scope flow per ADR-0014 § Q3 |
| `Audit` | every service in the chain | one structured-JSON log line per hop, schema fixed by ADR-0012 § Q4 |

The library does **not** authorize requests (that's SpiceDB / AuthZEN-facade's job), does **not** load secrets (caller passes already-loaded values via Config structs), does **not** call Keycloak's RFC 8693 token-exchange endpoint (NO-GO per ADR-0012), and does **not** discover audiences at runtime (Q2: static config wins).

---

## Setting up `Middleware` for a new backend API

```go
import (
    "net/http"
    apiauth "github.com/secforge/lib/api-auth"
)

// 1. Configure once at process start.
mw := apiauth.NewMiddleware(apiauth.MiddlewareConfig{
    Issuer:           "https://auth.secforge.local/realms/secforge-tenants",
    ExpectedAudience: "my-backend-svc",   // exactly this backend's audience
    JWKSEndpoint:     "https://auth.secforge.local/realms/secforge-tenants/protocol/openid-connect/certs",
    ReplayCache:      myValkeyReplayCache, // production: Valkey; tests: in-memory
    HTTPClient:       myMTLSAwareClient,
    Audit:            myAuditEmitter,      // optional but recommended
    WorkloadID:       "spiffe://secforge.local/ns/<ns>/sa/<sa>",
})

// 2. Wrap every protected route. Wrap calls Audit.LogHop on both
//    success and denial — every protected request produces an audit
//    line per ADR-0014 § Library API surface.
http.Handle("/api/orders", mw.Wrap(http.HandlerFunc(handleOrders)))

// 3. In the handler, fetch *Claims via the typed context key.
func handleOrders(w http.ResponseWriter, r *http.Request) {
    claims := apiauth.ClaimsFromContext(r.Context())
    if claims == nil {
        http.Error(w, "no claims (Wrap not in chain?)", http.StatusInternalServerError)
        return
    }
    // ... claims.Sub is the user, claims.Aud / claims.RealmRoles are
    // available; SpiceDB CheckPermission gates the actual data access
    // — Middleware does authn, never authz.
}
```

### What `ValidateInbound` checks (the 17-step chain)

Each step short-circuits on failure with the typed error documented in [ADR-0014 § Error-handling contract](../02-decisions/0014-api-auth-library-design.md#error-handling-contract):

1. `Authorization` header present + `Bearer ` prefix → `ErrInvalidToken`
2. JWT parses as JWS → `ErrInvalidToken`
3. Signature verifies against the JWKS (cached 1h, refreshed on `kid` miss) → `ErrInvalidToken`
4. `iss` exact match → `ErrInvalidToken`
5. `aud` contains `ExpectedAudience` → `ErrAudienceMismatch`
6. `exp > now` → `ErrTokenExpired`
7. `nbf <= now ± 30s` → `ErrInvalidToken`
8. `iat <= now ± 30s` → `ErrInvalidToken`
9. `DPoP` header present → `ErrDPoPMissing`
10. DPoP parses as JWS with embedded `jwk` → `ErrDPoPMismatch`
11. DPoP signature verifies → `ErrDPoPMismatch`
12. DPoP `htm == request.Method` → `ErrDPoPMismatch`
13. DPoP `htu == canonical_htu(request)` per [`dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md) → `ErrDPoPMismatch`
14. DPoP `iat` within ±60s → `ErrDPoPMismatch`
15. DPoP `jti` not in replay cache (atomic insert) → `ErrDPoPMismatch`
16. SHA-256 thumbprint of DPoP's embedded `jwk` matches access token's `cnf.jkt` → `ErrDPoPMismatch`
17. (Step 15's atomic insert covers the replay-cache write.)

---

## Setting up `Client.MintTokenForAudience` for a new outbound hop

`Client` is the BFF's outbound primitive. Backends typically don't call Keycloak themselves — they let the BFF mint per-call tokens.

```go
cli := apiauth.NewClient(apiauth.ClientConfig{
    TokenEndpoint:      "https://auth.secforge.local/realms/secforge-tenants/protocol/openid-connect/token",
    ClientID:           "my-bff",
    ClientAssertionPEM: pemBytesFromOpenBao,    // private_key_jwt PEM, RSA-2048
    AudienceList:       []string{"backend-a", "backend-b"},  // BFF_AUDIENCE_LIST
    SessionStore:       myValkeyAdapter,         // satisfies apiauth.SessionStore
    DPoPKey:            myECDSAPerPodKey,        // crypto.Signer; ECDSA P-256
    HTTPClient:         myMTLSAwareClient,
})

// In the per-request handler:
ctx := apiauth.ContextWithSessionKey(r.Context(), sessionID)
accessToken, err := cli.MintTokenForAudience(ctx, "backend-a")
if errors.Is(err, apiauth.ErrAudienceUnavailable) {
    // Q3 fallback: clear session, redirect to /login.
}
// `accessToken` is a JWT bound to your DPoP key (cnf.jkt set).
// Now mint a per-call DPoP proof scoped to the upstream URL and forward.
```

### Q3 fallback path (the most-overlooked failure mode)

If Keycloak rejects the refresh-with-expanded-scope (because the client doesn't have the audience scope mapped, or the refresh token expired, or scope was tampered with), `MintTokenForAudience` returns `ErrAudienceUnavailable`. The BFF MUST:

1. Clear the session cookie (`Set-Cookie: __Host-bff_sid=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax`).
2. Set `Location: /login` and respond 401.
3. Emit a `LogHop` line with `status=401` so the audit chain reflects the fallback.

Don't surface the error message to the user — return a generic JSON error body. Keycloak's `error_description` may leak internal scope names.

---

## Setting up `Audit.LogHop`

Every protected request produces audit lines. Backends emit once (inbound edge); BFFs emit three times per request (inbound, outbound-attempt, outbound-result).

```go
audit := apiauth.NewAudit(apiauth.AuditConfig{
    Writer: os.Stdout,                   // Promtail tails container stdout
    // Clock and WriteTimeout default to time.Now and 100ms respectively.
})

// Inbound edge of a backend (after Middleware succeeds).
audit.LogHop(r, /*hopIndex*/ 1, myWorkloadID, claims.Sub, "my-backend-svc", http.StatusOK)
```

The schema is fixed; field order matters (Loki regex queries depend on it):

```json
{"request_id":"...","hop_index":1,"caller_workload_id":"spiffe://...","caller_user_sub":"user-1","target_audience":"my-backend-svc","timestamp":"2026-05-01T12:34:56.789Z","endpoint":"GET /orders","status":200}
```

### `request_id` propagation

`LogHop` reads `X-Request-ID` from the request. If absent, it generates a fresh ID and writes it back to `req.Header` so downstream callers in the same process see it. Phase 9 backends add a tiny middleware that **also** writes the response `X-Request-ID` so chained services can pick it up over HTTP — `LogHop` itself only handles request-side propagation.

### Why the schema's field order matters

Loki LogQL uses regex to extract fields when you don't have a JSON parser pipeline. `{namespace="app"} |~ "request_id"` matches; `{namespace="app"} | json | request_id="..."` is more correct but heavier. The fixed field order means `awk -F'"' '/request_id/ {print $4}'` works on a tail stream.

---

## Reconstructing a call chain in Loki

```bash
# Substitute your request_id; logfmt query works for the schema above.
PASS=$(kubectl get secret -n observability kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -sk -u "admin:${PASS}" -G \
  "https://grafana.secforge.local/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="app"} |= "your-request-id-here"' \
  --data-urlencode "start=$(($(date +%s) - 3600))000000000" \
  --data-urlencode "end=$(date +%s)000000000"
```

The result is one log line per hop, sorted by timestamp. Sort by `hop_index` to reconstruct the chain logically rather than by clock skew.

---

## Common mistakes

### "`ValidateInbound` returns `ErrAudienceMismatch` on the BFF's own callback"

The BFF accepts session-tier tokens (after login) which carry `aud=<bff-id>`. If you wired Middleware on the BFF's `/api/*`, configure it with `ExpectedAudience=<bff-id>`, **NOT** the downstream API audiences. Mint downstream tokens via `Client.MintTokenForAudience` only for the upstream HTTP call to the backend.

### "`MintTokenForAudience` returns `ErrAudienceUnavailable` on every refresh"

Keycloak rejected the expanded scope. Check:

- The audience-mapper is configured as an **Optional** (not Default) client scope on the BFF client. Default scopes are always granted; Optional ones only when explicitly requested in the `scope` parameter — which is what `expandScope` does.
- The audience-mapper's `Included Custom Audience` matches your `BFF_AUDIENCE_LIST` value verbatim (case + path).
- Re-run `infrastructure/keycloak/clients/<bff>.sh` idempotently to ensure the mapper is in place.

### "`htu` mismatch on every DPoP request"

RFC 9449 §4.3: scheme + host lowercased, default port (443/80) omitted, no query string, **path verbatim** (no normalization). Browser/proxy normalization differences bite here. Log both expected and actual `htu` on mismatch and compare. If your BFF sits behind ingress-nginx, the BFF's `canonicalHTU` should derive scheme/host from `X-Forwarded-Proto` / `X-Forwarded-Host` — fail closed if either is absent (per [`dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md)).

### "Replayed `jti` accepted"

Replay-cache TTL must be ≥ DPoP `iat` window (60s) plus clock-skew tolerance (30s). The library uses 90s; if you wire a Valkey-backed cache with shorter TTL you'll re-open the window. Don't.

### "JWKS fetch hammered after every kid rotation"

The library refreshes JWKS **once** per `ValidateInbound` call when the kid is missing. After that, the cache is updated and subsequent calls observe the new key without re-fetching. If you see repeated fetches in metrics, check that the JWKS Server header is cacheable (Keycloak emits one).

---

## Troubleshooting

### Library tests pass but production fails

The test suite uses `httptest.Server` for Keycloak and an in-memory ReplayCache. Production uses a real Keycloak (mTLS terminated by the mesh post-7c) and a Valkey-backed ReplayCache. Wire-format differences land here:

- Keycloak's JWKS HTTP response includes `Content-Type: application/jwk-set+json` — the library accepts both `application/json` and the jwk-set variant; if your shim downgrades, fix the shim.
- Valkey replay-cache **must** atomic-insert (SETNX-equivalent). A simple `EXISTS` + `SET` is racy; use `SET ... NX EX 90`. The library's contract is "SeenWithin returns true if the second concurrent caller observes the same jti."

### `cnf.jkt` mismatch after BFF pod roll

Per [ADR-0011](../02-decisions/0011-bff-single-replica-local.md), DPoP keys are per-pod, in-memory. After a roll, the new pod's key thumbprint doesn't match the cached `cnf.jkt` on the user's access token, so DPoP validation fails. The library's `MintTokenForAudience` triggers a refresh-with-expanded-scope which rebinds the new token to the new pod's key. The user does not see this — it's transparent.

### Audit lines dropped after a Loki outage

If Loki/Promtail/the local stdout pipe slows down, `LogHop`'s 100ms write timeout fires; the line is dropped and `Audit.Dropped()` increments. **Wire a Prometheus gauge from `Dropped()`** if your service is audit-sensitive — losing audit lines silently is worse than the 100ms cost of a slow write. Phase 7b's "Secrets Guardrails" dashboard wires a similar pattern for `secrets.guardrail.bypass`.

---

## Verifying a deployment end-to-end

[`infrastructure/lib/api-auth/verify-integration.sh`](../../infrastructure/lib/api-auth/verify-integration.sh) packages the full check:

- **Layer 1**: scoped Go tests + build/vet/fmt (always runs).
- **Layer 2**: BFF `/healthz` + `/ready` + `/login` PAR redirect (runs when the BFF Deployment is up).
- **Layer 3**: 2-hop request chain → Loki query confirming both hop lines share one `request_id` (runs when Phase 9's hello-world backend is live).

---

## Constraints worth re-stating

- **Library API surface is fixed by [ADR-0014](../02-decisions/0014-api-auth-library-design.md).** Don't invent helpers — open an issue if you need one.
- **No new third-party deps.** `apps/lib/api-auth` uses only `lestrrat-go/jwx/v2` and stdlib. If you reach for a new dep in a fix, verify it's already in `apps/helloworld-bff/go.mod`.
- **No panics.** Every code path returns a typed error.
- **Library does not load secrets.** Caller passes already-loaded values via Config structs (per [ADR-0019](../02-decisions/0019-secret-distribution-interface.md)).
- **Audit log emits on every protected request, including denials.** Don't gate `LogHop` on success.
- **No RFC 8693 token-exchange.** Not now, not via "compatibility shim", not via "test-only path." NO-GO is final per [ADR-0012](../02-decisions/0012-token-exchange-feasibility.md). If a watching-brief trigger fires, the platform re-spikes — that's a separate phase, not a library extension.

---

## Re-evaluation triggers

Re-open this runbook when any of:

- ADR-0014 changes (new error type, new method, new config field).
- The Q3 outcome verification at [ADR-0014 § Observed Q3 behavior](../02-decisions/0014-api-auth-library-design.md#observed-q3-behavior-2026-05-01) lands a definitive (a) / (b) result and the library's behavior on the non-default outcome warrants a fast-fail tweak.
- A second BFF (Proposal Forge, Project Tracker, future PM app) goes live and surfaces a per-app config gotcha worth documenting.
- Phase 7c lands STRICT mTLS — the JWKS HTTP path becomes mTLS-protected and the runbook's "wire your mTLS-aware HTTPClient" line needs an example.
