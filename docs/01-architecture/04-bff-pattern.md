# BFF Pattern

> **Production note.** This is the reference Go BFF pattern (Valkey-backed sessions, per-pod DPoP keys). The deployed ecosystem apps (Portal, Control, Member Hub, Proposal Forge) are TypeScript/Hono services that use **HttpOnly-cookie sessions** and do **not** run Valkey; this doc describes the pattern for new first-class Go services. Substrate deltas: ingress is the **Istio gateway** (not ingress-nginx); `X-Forwarded-*` headers are set by the Istio gateway. See [PLAN.md](../../PLAN.md) and [00-overview.md](./00-overview.md).

> Companion: [docs/01-architecture/01-iam-platform.md](./01-iam-platform.md), [docs/01-architecture/07-service-mesh.md](./07-service-mesh.md).
> Reference implementation: `apps/lib/api-auth` + `apps/lib/secrets` (the `helloworld-bff` demo that exercised them was removed); scaffold at `templates/app-repo/`.
> Operational runbook: [docs/03-runbooks/bff-operations.md](../03-runbooks/bff-operations.md).
> Secret distribution: [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md) — the BFF reads `private_key_jwt` directly from OpenBao via SPIFFE-bound JWT auth (the "first-class app" path; no VSO, no K8s Secret).

This document fixes the design decisions that determine the BFF's wire behaviour, session storage, and identity propagation. It is the single place those decisions are settled — Phase 6.6 implements; this doc decides.

> **Local deviation, load-bearing**: the BFF Deployment runs `replicas: 1` in the local edition, not the `replicas: 2` from the Phase 6 prompt. The constraint is the per-pod in-memory DPoP keypair (see [§ DPoP key lifecycle](#dpop-key-lifecycle)); a second replica would have a different jkt and could not mint valid proofs for the first replica's tokens. Cloud edition unblocks `replicas: ≥ 2` by moving to per-session DPoP keys persisted in Valkey, encrypted with an OpenBao Transit KEK. **Rationale, alternatives, re-evaluation criteria**: [ADR-0011 — BFF runs as a single replica in the local edition](../02-decisions/0011-bff-single-replica-local.md).

---

## Goals

1. **The browser never holds OAuth tokens.** Period. No localStorage, no sessionStorage, no JS-readable cookie. The browser receives an opaque session ID; everything sensitive lives server-side.
2. **Every BFF→backend hop is authenticated by both** an RFC 9068 access token AND a per-request DPoP proof bound to the BFF pod's keypair.
3. **Session state survives BFF replica scheduling** but **NOT process restarts** — the in-memory DPoP keypair changes, which forces a token refresh on the first post-restart upstream call. Sessions stay valid; existing access tokens become inert.
4. **Strict security headers on every response.** A user who somehow gets HTML back gets a strict CSP, HSTS, frame-ancestors-deny, etc., even on error responses.
5. **Same wire protocol works in cloud.** Only Keycloak base URL, OpenBao address, Valkey address, and trust domain change.

---

## Wire shape

```
┌────────────┐    1. GET /login                  ┌──────────┐
│  Browser   │ ─────────────────────────────────►│   BFF    │
│            │                                   │          │
│            │◄──── 302 to Keycloak /authorize ──│ ~ 8 KB   │
│            │      (request_uri from PAR)       │ memory   │
│            │                                   │ pod      │
│            │    2. Auth at Keycloak            └──────────┘
│            │ ─────────────► [Keycloak]            │  ▲
│            │ ◄────────────                        │  │
│            │                                      │  │ Valkey:
│            │    3. GET /callback?code=...         │  │ session
│            │ ─────────────────────────────────►   │  │ store
│            │                                      │  │
│            │       BFF exchanges code, mints      │  │
│            │       DPoP proof, sets cookie        │  │
│            │ ◄──── 302 to / + Set-Cookie sid=... ─┤  │
│            │                                      │  │
│            │    4. Subsequent requests with       │  │
│            │       cookie sid=...                 │  │
│            │ ─────────────────────────────────►   │  │
│            │                                      ▼  │
│            │       BFF: cookie → session → tokens     │
│            │       BFF mints DPoP proof for backend   │
│            │       BFF calls backend with             │
│            │         Authorization: DPoP <jwt>        │
│            │         DPoP: <proof>                    │
│            │                                          │
│            │ ◄──── proxied response ──────────────────┘
│            │                                          │
└────────────┘    5. POST /logout                       │
                  → revoke + delete + 302 to KC end-session
```

Three URL surfaces:

| URL | Purpose | Where served |
|---|---|---|
| `https://app.secforge.dev/login` | Initiate OIDC flow | BFF |
| `https://app.secforge.dev/callback` | OIDC code-exchange | BFF |
| `https://app.secforge.dev/logout` | End session | BFF |
| `https://app.secforge.dev/api/*` | Reverse-proxy to backend | BFF |
| `https://app.secforge.dev/*` | Reverse-proxy to frontend | BFF |

The BFF never speaks HTML directly. Anything HTML-rendered comes from the frontend pod (Phase 9+); the BFF's only response bodies are 302 redirects, 401 JSON errors, and proxied bytes.

---

## Cookie shape

| Attribute | Value | Why |
|---|---|---|
| Name | `__Host-bff_sid` | The `__Host-` prefix forbids the cookie from being set with a `Domain` attribute, forces `Secure`, forces `Path=/`. Browser-enforced hardening. |
| Value | 32 random bytes, base64url-encoded → 43 chars | Opaque ID; the actual session lives in Valkey under this key |
| `HttpOnly` | true | Inaccessible to JavaScript; XSS cannot exfiltrate |
| `Secure` | true | Only sent over HTTPS — and `__Host-` enforces this anyway |
| `SameSite` | `Lax` | Sent on top-level navigations (so `/login` redirects work) but not on cross-site sub-resource requests; mitigates CSRF for typical flows. **Not** `Strict` because that breaks the OIDC redirect flow. |
| `Path` | `/` | Forced by `__Host-` |
| `Max-Age` | unset (session cookie) | Cookie disappears when browser closes; Valkey TTL is the real expiry. Setting a max-age in the cookie creates a UX where users "stay logged in" past their refresh-token TTL on the server, with a 401 surprise. |

### CSRF defence

`SameSite=Lax` + the `Origin` header check on state-changing endpoints. The BFF rejects `POST /logout`, `POST /api/*` with `mutating` semantics if the `Origin` header is missing or doesn't match the BFF's origin. No anti-CSRF tokens — `SameSite=Lax` plus origin-header validation is sufficient for first-party APIs and avoids the token-management overhead.

---

## Valkey session schema

### Key format

```
bff:session:{sid}             # the session itself
bff:session:{sid}:refresh-lock  # single-flight lock during token refresh
bff:login:{state}             # in-flight login flow (PKCE verifier, etc.)
bff:userinfo:{sub}:{...}      # reserved for future per-user caches; not used in 6.6
```

`{sid}` is the cookie value (43 base64url chars). `{state}` is the OAuth `state` parameter, 32 random bytes base64url.

### Session value (JSON)

```json
{
    "v": 1,
    "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "preferred_username": "jason.upole",
    "session_state": "3f...",                  // Keycloak session ID, used for SLO matching
    "access_token": "<opaque to BFF; signed by KC>",
    "refresh_token": "<opaque to BFF; signed by KC>",
    "id_token": "<JWT; kept ONLY for logout id_token_hint>",
    "access_exp": 1714508400,                  // unix seconds; access token expiry
    "refresh_exp": 1714530000,                 // unix seconds; refresh token expiry
    "scope": "openid profile email",
    "dpop_jkt_at_issue": "abc123...",          // jkt the access token is bound to
    "created_at": 1714504800,
    "last_seen": 1714504800
}
```

The version field (`v: 1`) lets us evolve the schema without ambiguity; on read-mismatch the BFF treats the session as invalid and forces re-auth.

### Login-flow value (JSON; short-lived, ~5 min TTL)

```json
{
    "v": 1,
    "pkce_verifier": "...",                    // 43-char URL-safe random
    "nonce": "...",                            // OIDC nonce; verified in id_token
    "redirect_after_login": "/some/path",      // where the user came from
    "created_at": 1714504800
}
```

The OAuth `state` parameter IS the Valkey key (not stored in the value); fetching the value on /callback simultaneously validates `state` (key exists?) and returns the verifier.

### TTL strategy

- `bff:session:{sid}`: TTL = `min(refresh_exp - now, 30 min idle window)`. Reset to 30-min idle on each authenticated request via `EXPIRE`. Hard cap at refresh_exp; the BFF will not extend a session past its refresh-token TTL.
- `bff:session:{sid}:refresh-lock`: 5-second TTL. Held during a refresh by exactly one BFF replica.
- `bff:login:{state}`: 5-min TTL. Long enough for slow auth (TOTP enrollment), short enough to bound replay window.

### Concurrent refresh serialization

When access_token is within 30 seconds of expiry, the BFF refreshes. Two concurrent requests from the same browser tab race to refresh; without coordination, one's refresh succeeds, the other gets `invalid_grant` (Keycloak refresh-rotation invalidates the old refresh token).

Mechanism — single-flight lock via Valkey `SET NX EX`:

```
1. Request arrives, finds access_token within 30s of expiry.
2. Try `SET bff:session:{sid}:refresh-lock {pod-id} NX EX 5`.
3. If acquired:
       a. Call Keycloak refresh.
       b. Update session JSON with new tokens.
       c. DEL the lock key (best-effort; TTL is the safety net).
4. If not acquired:
       a. Loop: GET bff:session:{sid} every 50ms for up to 4s.
       b. As soon as the stored access_token expiry is later than what we saw, use it.
       c. If 4s elapses without an update, fail the request with 503 (caller retries).
```

5-second lock TTL is the safety net for a BFF pod that crashes mid-refresh; 4-second wait timeout in the loser path leaves 1 second of slack.

---

## DPoP key lifecycle

> Phase 6.6 spec: "fresh ECDSA P-256 keypair on startup, in memory only." Decisions below resolve the implications.

### Per-pod, not per-session

A single ECDSA P-256 keypair is generated by `crypto/ecdsa.GenerateKey(elliptic.P256(), rand.Reader)` on `main()` startup. It lives in a `*ecdsa.PrivateKey` field on a shared service struct. Every DPoP proof from this pod uses this keypair. The `jkt` (RFC 7638 thumbprint of the public key in JWK form) is computed once and cached.

**Why per-pod, not per-session**: per-session DPoP keys would have to be persisted in Valkey to survive request-balancing across replicas, which means encrypted-at-rest plus a key-encryption-key fetched from OpenBao Transit on every request. That's a real implementation. We're not building it in Phase 6 because the local edition runs **one BFF replica** (see "Replica strategy" below), which makes per-pod keys correct and trivial.

### Replica strategy in Phase 6 (local)

`replicas: 1` for the helloworld-bff Deployment in Phase 6.8. The phase prompt asks for 2; this is an explicit deviation. HPA is not enabled.

Why: with 2 replicas, an access token bound to pod-A's jkt cannot be presented from pod-B (DPoP proof would fail backend validation). Workarounds (sticky sessions, shared per-cluster keypair, per-session keys) all add complexity that's wasted locally. Single replica is fine: there are no real users; pod restart is rare; cloud edition will revisit.

In **cloud** the right answer is per-session DPoP keys persisted encrypted in Valkey. That's a Phase-pre-migration item, named in PLAN.md.

### Pod restart consequence

When the BFF pod restarts, the in-memory keypair is gone. New keypair, new jkt. Existing access tokens in Valkey are bound to the old jkt; they are now inert.

The BFF's next-request behaviour:

1. Detect inert access token: presence in session, but its `dpop_jkt_at_issue` doesn't match the live pod jkt.
2. Force a refresh-token exchange BEFORE making any upstream call. The refresh produces a new access token bound to the new jkt; update session.
3. Proceed normally.

This is one extra round-trip on the first request after a pod restart. The post-restart path requires that refresh tokens NOT carry a `cnf.jkt` — otherwise Keycloak would reject the refresh-grant call when the BFF's new pod presents a DPoP proof with a different jkt.

**Verified in Keycloak 26.0 source** (`TokenManager.java`, methods `getConfirmation()` line 1366-1372 and `verifyRefreshToken()` line 869-910): refresh-token DPoP-binding (`cnf.jkt` on the refresh token + jkt-match check on the refresh grant) is applied **only when the client is public** (`isPublicClient()`). For confidential clients, neither path runs — Keycloak relies on the client credential (in our case, `private_key_jwt` on every token call) to bind the refresh, exactly as RFC 9449 §5 prescribes. Confirmed against the running `helloworld-bff` client (`publicClient: false`, `clientAuthenticatorType: client-jwt`, `dpop.bound.access.tokens: true`).

> **Invariant (load-bearing): the BFF Keycloak client MUST remain `publicClient: false`.** The post-restart recovery path documented above depends on it. If the client is ever changed to public, every BFF pod restart will invalidate every active session because Keycloak will reject refresh calls whose DPoP proof presents a different jkt than the one bound to the refresh token at issuance. This isn't an aspirational defense-in-depth choice; it's a functional requirement of the per-pod-DPoP-key design (see [ADR-0011](../02-decisions/0011-bff-single-replica-local.md)). When per-session DPoP keys land for the cloud edition, this invariant relaxes — but until then, do not flip the client to public.

### `htu` canonicalization rule (settles CLAUDE.md gotcha #3 once)

> **Canonical source:** [`docs/06-reference/dpop-htu-canonicalization.md`](../06-reference/dpop-htu-canonicalization.md). The rule below is included here as the BFF's binding spec; every other consumer (Phase 6b-1's `apps/lib/api-auth/`, Phase 9+ backends, future BFFs) reads from the canonical doc. Closes F-ADR-3 — central reference replaces per-component re-derivation.

The DPoP `htu` claim is the **HTTP target URI** of the request the proof secures. Canonicalization is the source of subtle bugs.

**The rule, applied at every site that mints or validates a DPoP proof:**

```
canonical_htu(url) =
    lowercase(scheme) + "://"
    + lowercase(host)
    + (port if non-default-for-scheme else "")
    + path                                   // verbatim, including trailing slash if any
    // NO query string, NO fragment, NO username/password
```

Where:

- `default-for-scheme`: 443 for https, 80 for http. Any other port is included verbatim.
- `path`: kept as-is — the BFF does not normalize trailing slashes, percent-encoding, etc. The frontend / proxy must send the exact same path the BFF uses; mismatched normalization is an explicit incident, not silently masked.

**The BFF computes `htu` from request headers, not its own URL config.** For inbound requests, the canonical `htu` is built from `X-Forwarded-Proto` and `X-Forwarded-Host` (set by ingress-nginx) plus the request path. For outbound requests (BFF → backend), `htu` is the exact URL the BFF dialed.

**The `htu` MUST be consistent across the request chain.** ingress-nginx is configured with `proxy_redirect off` and forwards `X-Forwarded-Host` = `app.secforge.dev`, never the internal Service hostname. The BFF rejects requests whose `X-Forwarded-Host` doesn't match the configured `BFF_PUBLIC_ORIGIN` env var.

**Fail closed on missing forwarded headers.** If `X-Forwarded-Proto` or `X-Forwarded-Host` is absent on an inbound request that requires DPoP validation, the BFF returns 400 with `{"error":"missing_forwarded_headers"}`. **The BFF MUST NOT fall back to `r.Host` or `r.TLS != nil` to synthesise the missing header values.** Those fallbacks would silently re-enable connections that bypassed ingress-nginx (e.g., from a misconfigured port-forward, a debug Service, or a future direct-pod-IP probe), producing DPoP proofs whose `htu` matches an internal-only URL. That is exactly the gotcha CLAUDE.md §"Local-specific gotchas to remember" #3 warns about — and the failure mode is silent (DPoP signs whatever the BFF computed; the backend validates against its own canonical URL; mismatch returns 401 with no obvious cause). Fail-closed makes the misconfiguration loud at the inbound boundary instead.

This rule is the single source of truth. Phase 6.6 implements `dpop.go` against it.

---

## Identity propagation: BFF → backend

### Decision: forward the Keycloak access token (option A), with DPoP rebinding to BFF jkt

The BFF takes the access token from Valkey and uses it directly as the upstream Bearer token. A fresh DPoP proof is minted per upstream call using the BFF's pod keypair; the access token's `cnf.jkt` claim names that keypair. The backend validates: signature (RFC 9068), audience (the backend's client_id or a configured value), expiry, AND that the DPoP proof signature matches the public key whose thumbprint is in `cnf.jkt`.

### Why option A (forward access token), not B (mint internal JWT) or C (header assertion + mTLS)

**Compromised-BFF blast radius**:

| Option | What an attacker gets if BFF is compromised | Notes |
|---|---|---|
| A — forward access token | Any session's access token, valid for its TTL (~5 min). DPoP-bound to the BFF's jkt — attacker also needs the BFF's in-memory ECDSA private key, which they have if they own the BFF process. Effectively: full impersonation of any logged-in user, until access tokens expire and refresh requires the refresh token (also in Valkey + the BFF's private_key_jwt key). | DPoP-binding limits but does not eliminate replay outside the BFF. Backend can detect anomalous traffic via the BFF's SPIFFE ID. |
| B — BFF mints internal JWT | The BFF's signing key. Attacker can mint arbitrary internal JWTs for any user, any audience the key signs for. Identical practical blast radius to A; adds the cost of running an internal JWT signing+rotation pipeline. | No security win over A unless the internal JWT has narrower scope than the upstream token — but that's RFC 8693 territory, which composes onto A as well. |
| C — header assertion + mTLS-only trust | Attacker forwards any user identity via headers. The backend trusts the BFF's mesh-identity (`spiffe://.../sa/helloworld-bff`) and the headers it sets. **Compromised BFF impersonates anyone**, with no token-level evidence on the wire. | Operationally tempting, security-wise the worst — there's nothing the backend can re-verify. Specifically rejected. |

### Composition with Phase 6b (RFC 8693 token-exchange)

Phase 6b layers an RFC 8693 token-exchange step: the BFF takes the inbound user access token, calls Keycloak's token-exchange endpoint, and gets back a **downstream-audience-scoped** token (e.g., `aud=helloworld-backend` instead of `aud=app.secforge.dev`). That downstream token is what gets forwarded.

This composes cleanly with option A — same wire shape (Authorization + DPoP), just a different opaque token. The backend's validation logic is unchanged: `iss=Keycloak`, `aud=its-own-client-id`, `cnf.jkt=BFF's-jkt`. Option B or C would either duplicate the token-exchange machinery or bypass it.

When 6b lands, the BFF's `proxy.go` gains a single `tokenExchange()` step before each upstream call (cached for the access-token TTL); everything else stays the same.

### Backend API authentication contract

The backend (Phase 9) validates each incoming request:

1. `Authorization: DPoP <jwt>` header present.
2. `DPoP: <proof-jwt>` header present.
3. JWT signature validates against Keycloak JWKS; `iss` matches; `aud` matches the backend's configured audience; `exp` valid; `typ=at+jwt` (RFC 9068).
4. JWT `cnf.jkt` matches the JWK thumbprint in the DPoP proof header.
5. DPoP proof: signature validates against the public key in its `jwk` header; `htm` matches HTTP method; `htu` matches the canonical URI; `iat` within ±60s; `jti` not seen recently (replay-cache, 5-min window); `ath` = base64url(SHA-256(access_token)).
6. **Then** the backend asks SpiceDB for the per-resource permission decision (Phase 4, via the AuthZEN façade).

Backend MUST reject any request that satisfies #1-3 but fails #4 with 401, with `WWW-Authenticate: DPoP error="invalid_token"`. SpiceDB is not consulted unless DPoP binding is verified — DPoP failure is a token-replay signal, treat as adversarial.

> **Note for Phase 6b's `apps/lib/api-auth/` validator**: on BFF→backend calls, the DPoP proof's `jkt` matches the **immediate caller (BFF pod)**, not the browser. The browser never holds a DPoP key. The validator binds to whoever signed the proof on the wire — do not assume browser-key continuity, do not write the validator to expect a single key across a user's chain of hops. Each hop re-binds.

---

## CSP nonce plumbing

> Settles "where does the nonce come from, how does it travel, can it be reused."

### Generation site

A request-scoped middleware in `headers.go` generates a fresh 16-byte cryptographically-random nonce per request via `crypto/rand.Read` (NOT `math/rand` — predictable nonces would enable CSP bypass; closing F-ADR-4). The nonce is base64url-encoded → 22 chars, lives in the request context (`context.WithValue`), and is included in CSP violation reports for traceability. Every response — even error responses, even redirects — gets a CSP header that includes this nonce.

### Plumbing to the frontend

For requests that the BFF reverse-proxies to the frontend (Phase 9+):

1. BFF middleware generates the nonce, attaches to context.
2. BFF reverse-proxy (`proxy.go`) sets a request header `X-CSP-Nonce: <nonce>` on the upstream call to the frontend. The frontend reads this header and inlines the nonce in `<script nonce="...">` and `<style nonce="...">` tags during server-side rendering.
3. BFF response middleware sets `Content-Security-Policy: ... 'nonce-<nonce>' ...` on the proxied response. The browser only allows inline scripts/styles whose `nonce=` matches.

Both header values use the same nonce. If the frontend caches an HTML page, the browser will reject the inlined scripts because the response CSP nonce changed but the HTML's inline nonce didn't. The frontend MUST NOT cache rendered HTML; per-request server-side rendering is required.

### Reuse: forbidden

A nonce is bound to a single response. The BFF does not reuse nonces across requests, does not cache them, does not store them in Valkey. After the response goes out, the nonce is unrecoverable.

### CSP policy itself (Phase 6.6 sets, 6.10 verifies)

```
Content-Security-Policy:
    default-src 'none';
    script-src 'self' 'nonce-{nonce}' 'strict-dynamic';
    style-src 'self' 'nonce-{nonce}';
    img-src 'self' data:;
    font-src 'self';
    connect-src 'self';
    frame-ancestors 'none';
    base-uri 'none';
    form-action 'self' https://auth.secforge.dev;
    require-trusted-types-for 'script';
    upgrade-insecure-requests
```

`form-action` includes Keycloak's origin to allow the OIDC redirect's hidden form-post flow if used. `frame-ancestors 'none'` is the X-Frame-Options DENY equivalent; both are sent for legacy-browser compatibility.

---

## Logout sequence

```
1. POST /logout arrives. CSRF-check: Origin header == BFF_PUBLIC_ORIGIN; if not, 403.
2. Read session from Valkey by cookie ID. If none, jump to step 5 (already logged out).
3. DEL bff:session:{sid} — local invalidation, atomic. After this point the cookie is useless even if logout fails downstream.
4. Set-Cookie: __Host-bff_sid=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax — cookie cleared.
5. Best-effort: revoke refresh_token at Keycloak's RFC 7009 revocation endpoint (POST /realms/.../protocol/openid-connect/revoke, private_key_jwt auth).
       - Failure mode: log structured event {"event":"logout_revoke_failed","sub":...,"err":...} and continue.
       - The local session is already gone (step 3); the cookie is cleared (step 4). The refresh token remains valid at Keycloak for its TTL, BUT a third party would need to (a) have stolen it from Valkey before step 3, (b) hold the BFF's private_key_jwt key, and (c) be able to dial Keycloak. Marginal residual risk; fail-open is correct.
6. 302 to Keycloak end-session endpoint:
       https://auth.secforge.dev/realms/secforge-tenants/protocol/openid-connect/logout
           ?id_token_hint={id_token}
           &post_logout_redirect_uri={BFF_PUBLIC_ORIGIN}/
       (id_token_hint is required by Keycloak to correlate the logout to a specific session.)
```

### Failure semantics matrix

| Step | Failure behaviour | Cookie cleared? | Local session gone? | Refresh token revoked? |
|---|---|---|---|---|
| 2 (no session) | Skip 3-5; redirect to KC end-session with no hint | Yes (best-effort) | n/a | n/a |
| 3 (Valkey down) | 503; cookie NOT cleared (we don't know if local session was deleted) | No | Unknown | No |
| 4 (response error) | Already past the point; no rollback | Already sent | Yes | Pending |
| 5 (KC revoke fails) | Continue; log; redirect | Yes | Yes | No |
| 6 (KC end-session unreachable) | User sees Keycloak error; their local cookie is already cleared | Yes | Yes | Whatever step 5 produced |

Step 3 failure (Valkey down) is the one case where we return an error to the user instead of best-effort logout. Without atomic local invalidation, we cannot guarantee the cookie's session is dead, and the user's perception of "I logged out" would be wrong. The user retries when Valkey is back.

### Back-channel logout (SLO)

OIDC `backchannel_logout_uri` for "Keycloak logs the user out, the BFF needs to invalidate sessions" — DEFERRED.

When implemented, the BFF will:

1. Expose `POST /backchannel-logout`, accessible from Keycloak's pod IP (NetworkPolicy + AuthorizationPolicy gate).
2. Validate the inbound JWT logout token: signed by Keycloak, `iss=Keycloak`, `aud=helloworld-bff`, `events.http://schemas.openid.net/event/backchannel-logout` claim present, `sid` claim matches a known session.
3. Find sessions in Valkey by `session_state` index (requires a secondary index `bff:session-state:{sid}` → `{cookie-sid}` written at /callback time).
4. DEL those sessions.

Tracked in PLAN.md as a Phase 6 follow-up; not blocking Checkpoint B.

---

## What's deferred to "decided in PR" (Phase 6.6)

The following are intentionally NOT pre-decided here. The Phase 6.6 PR settles them:

- Logging field names (subject to org-wide log schema; default to `event`, `sub`, `req_id`, `lat_ms`, `err`).
- Env var names (default convention: `BFF_*` prefix, all caps, e.g. `BFF_PUBLIC_ORIGIN`, `BFF_KEYCLOAK_ISSUER`, `BFF_VALKEY_ADDR`).
- Health/readiness probe paths and shapes (`/healthz` returns 200 always; `/ready` returns 200 only when Valkey, OpenBao, and Keycloak JWKS are reachable; both responses are JSON `{"ok":true}` — but the precise probe interval/timeouts are in the Deployment manifest).
- Dockerfile structure (multi-stage, distroless final, nonroot UID 65532 — see Phase 6.7).
- Error response bodies for non-auth errors (default `{"error":"<slug>","request_id":"..."}` JSON; status codes per class).

---

## Hardening posture summary

| Property | Value | Rationale |
|---|---|---|
| Cookie name | `__Host-bff_sid` | Browser-enforced Path=/, Secure, no Domain |
| Cookie value | 32-byte CSPRNG, base64url | Opaque to browser; session lookup in Valkey |
| Cookie attributes | HttpOnly, Secure, SameSite=Lax, Path=/, no Max-Age | Standard locked-down session-cookie pattern |
| Tokens in browser | None | BFF holds them server-side |
| OAuth flow | Authorization Code + PAR + DPoP + PKCE-S256 | OAuth 2.1; required by Keycloak client config |
| Refresh-token storage | Valkey, encrypted-at-rest at Valkey level (Phase 5 didn't enable; tracked) | Future-Phase improvement |
| DPoP keypair | per-pod ECDSA P-256, in-memory only | Process-local; pod restart triggers token refresh |
| BFF→backend identity | RFC 9068 access token (forwarded) + DPoP proof + Istio mTLS SVID | Triple-bound: token, key, mesh |
| CSP | nonce-based, default-src 'none', strict-dynamic | Inline-script blocking by default |
| HSTS | `max-age=63072000; includeSubDomains; preload` | 2-year, on local too — production-realistic muscle memory |
| Logout | Local invalidation FIRST, then best-effort revoke, then KC end-session | Cookie-killed before any failure point |
| Replicas | 1 (local edition) | Per-pod DPoP keypair; cloud will revisit with per-session keys |

---

## Migration to cloud

| Concept | Local | Cloud |
|---|---|---|
| BFF replicas | 1 | 2-3 with per-session DPoP keys persisted in Valkey (encrypted via OpenBao Transit KEK) |
| Cookie domain | `app.secforge.dev` (no `Domain`, only `__Host-` allows this) | `app.<org>.com` (still no `Domain` attribute; `__Host-` preserved) |
| Valkey | single pod | ElastiCache Valkey, primary + replicas, encryption-at-rest enabled |
| Keycloak issuer | `https://auth.secforge.dev/realms/secforge-tenants` | `https://auth.<org>.com/realms/<tenant>` |
| OpenBao Transit KEK for session-key encryption (cloud) | n/a (no per-session keys) | New key, BFF role binding |

The wire protocol does not change. The BFF code does not change except for replica config, the per-session-key codepath being enabled, and ENV-driven URLs.
