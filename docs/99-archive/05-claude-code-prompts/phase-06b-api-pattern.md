# Phase 6b-1 — API Auth Pattern (audience-at-login)

> **Navigation:** ⬅ [Previous: Phase 6b-0 — Token-exchange spike](./phase-06b-0-token-exchange-spike.md) · [Next: Phase 7 — Observability](./phase-07-observability.md) ➡ (or run [Phase 6b-2 — Outbound Secrets](./phase-06b-2-outbound-secrets.md) in parallel) · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 6 · Phase 6b-0 (NO-GO outcome) · [ADR-0012 § Resolution 2026-05-01](../02-decisions/0012-token-exchange-feasibility.md#resolution-2026-05-01) · [ADR-0014](../02-decisions/0014-api-auth-library-design.md)
> **Blocks:** Phase 9 (Hello World — first real consumer of the library) · Phase 10 · Phase 11
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ Ready to execute (was ⏸️ Blocked on ADR-0012 design conversation; **resolved 2026-05-01** — Q1-Q4 design decisions committed in ADR-0012 § Resolution; library contract committed in ADR-0014; this prompt rewritten as runnable).
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2 days

**Prerequisites:**
- Phase 6 ✅ — Istio Ambient + helloworld-bff deployed and verified end-to-end (browser→BFF login flow works)
- Phase 7 ✅ — Loki / Tempo / metrics live so the audit log + trace propagation work this phase emits has somewhere to go
- [ADR-0012 § Resolution (2026-05-01)](../02-decisions/0012-token-exchange-feasibility.md#resolution-2026-05-01) ✅ — the four open design questions are answered
- [ADR-0014](../02-decisions/0014-api-auth-library-design.md) ✅ — library API contract is the spec for sections 2-5 below

This phase implements `apps/lib/api-auth/` per ADR-0014's contract. The library's surface is fixed by ADR-0014; this prompt is the implementation runbook.

---

## Phase split

PLAN.md splits 6b-1 (API auth) and 6b-2 (outbound secrets + guardrails) into independent 2-day phases. They share architecture/runbook context but ship separately. **This file covers 6b-1 only.** 6b-2 lives in [phase-06b-2-outbound-secrets.md](./phase-06b-2-outbound-secrets.md).

---

## Goal

Build the reusable `apps/lib/api-auth/` Go library and wire `helloworld-bff` as its first consumer. Per ADR-0014:

- **Inbound (Middleware):** JWT signature + `iss`/`aud`/`exp`/`nbf`/`iat` + DPoP-binding validation against Keycloak's JWKS — backend APIs use this to gate user-tier requests.
- **Outbound (Client):** mint downstream-API-scoped, DPoP-bound tokens from the user's session via Keycloak refresh with expanded `scope` (audience-at-login, NOT RFC 8693 token-exchange — see ADR-0012 NO-GO). Q3's try-expand-fallback-relogin path lives here.
- **Audit (Audit):** emit one structured-JSON log line per hop carrying the SPIFFE+request-id schema from Q4 so a Loki query of `{request_id="..."}` reconstructs the full call chain.

Phase 9 (Hello World) is the first non-BFF consumer. Phase 10 apps reuse the library unchanged.

---

## What you (the operator) need to do first

1. Skim [`docs/01-architecture/04-bff-pattern.md`](../01-architecture/04-bff-pattern.md) (Phase 6) so the API-side terminology matches the BFF's.
2. Skim [ADR-0014 § Library API surface](../02-decisions/0014-api-auth-library-design.md#library-api-surface) — that's the contract you are NOT free to deviate from.
3. Confirm Phase 7 is closed: BFF traces reach Tempo, BFF logs reach Loki, Prometheus targets `helloworld-bff` UP. Section 7's verification depends on these.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 6b-1 of the SecForge Local Edition platform build.

Read in order before doing anything:
  1. CLAUDE.md
  2. PLAN.md (specifically the Phase 6b-1 detail block + the table row)
  3. docs/02-decisions/0012-token-exchange-feasibility.md § Resolution (2026-05-01)
  4. docs/02-decisions/0014-api-auth-library-design.md (the library contract — this is your spec)
  5. docs/01-architecture/04-bff-pattern.md (Phase 6 BFF; the library's first consumer)
  6. docs/05-claude-code-prompts/phase-06b-api-pattern.md (this doc)

Goal: implement apps/lib/api-auth/ per ADR-0014's contract and wire helloworld-bff
as the first consumer. RFC 8693 token-exchange is OUT (ADR-0012 NO-GO);
audience-at-login with try-expand-fallback-relogin is IN.

Constraints (tight):
- The library's public API is fixed by ADR-0014. Do not invent new surface.
  If a missing helper is genuinely needed, stop and surface as a spec
  ambiguity to the operator before adding it.
- Library MUST NOT panic on any input. All paths return typed errors.
- Library MUST NOT load its own secrets. The consuming app passes already-
  loaded values via Config struct.
- No new third-party dependencies beyond what helloworld-bff already pulls
  in (lestrrat-go/jwx/v2, coreos/go-oidc/v3, redis/go-redis/v9, etc.).
  Check go.mod before adding anything new.
- 150-300 LoC total across the library. If you're at 400, something's wrong.
- Audit log MUST emit on every protected request including denials.
- The library does NOT call Keycloak's RFC 8693 token-exchange endpoint.
  If you find yourself adding `grant_type=urn:ietf:params:oauth:grant-type:
  token-exchange` you've taken a wrong turn — stop and re-read ADR-0012.

═══════════════════════════════════════════════════════════════════════════
Section 1 — Verify or create the apps/lib/ scaffolding
═══════════════════════════════════════════════════════════════════════════

The Fix-after-07 remediation package may have already created apps/lib/ as a
shared module location. Check:

  ls apps/lib/ 2>/dev/null

If it exists with a go.mod:
  - Confirm module path is `github.com/secforge/lib` (or whatever the existing
    convention is) — read the existing go.mod
  - Skip to Section 2

If it does NOT exist (Fix-after-07 hasn't run yet):
  - Create apps/lib/ with go.mod declaring module `github.com/secforge/lib`
  - go.mod uses the same Go version as helloworld-bff (1.25 today)
  - Add a top-level README.md briefly stating: "Shared Go libraries used by
    SecForge BFFs and backend APIs. Each subdirectory is a sibling package.
    Public API contracts are documented in docs/02-decisions/."
  - Do not add any subdirectories yet — Section 2 creates apps/lib/api-auth/.

Verify the module builds clean:
  cd apps/lib && go build ./...

═══════════════════════════════════════════════════════════════════════════
Section 2 — Define apps/lib/api-auth/ package structure
═══════════════════════════════════════════════════════════════════════════

Create apps/lib/api-auth/ with these files (skeleton only — implementations
land in Sections 3-5). Each file's package declaration is `package apiauth`.

  apps/lib/api-auth/
    ├── go.mod              # module github.com/secforge/lib/api-auth
    ├── types.go            # Claims struct, Config struct, exported types
    ├── errors.go           # typed errors per ADR-0014 § Error-handling contract
    ├── middleware.go       # type Middleware + ValidateInbound (Section 3)
    ├── client.go           # type Client + MintTokenForAudience (Section 4)
    ├── audit.go            # type Audit + LogHop (Section 5)
    └── doc.go              # package-level godoc with link to ADR-0014

types.go:
  - Claims: Sub, Aud []string, RealmRoles []string, SPIFFEID *string,
    DPoPThumbprint string. Fields ADR-0014 § Library API surface
    enumerates as Middleware.ValidateInbound's return.
  - Config (separate Configs for Middleware and Client): see ADR-0014's
    Middleware/Client constructors, derive field set from there.
    No env-var defaults inside the library — caller passes everything.

errors.go:
  - Sentinel errors: ErrInvalidToken, ErrTokenExpired, ErrAudienceMismatch,
    ErrDPoPMissing, ErrDPoPMismatch, ErrAudienceNotConfigured,
    ErrAudienceUnavailable, ErrKeycloakUnreachable.
  - Use errors.New (not fmt.Errorf) for sentinels so callers can errors.Is
    them.
  - Each error's docstring states the canonical HTTP mapping per ADR-0014
    § Error-handling contract.

doc.go: a 10-line package summary citing ADR-0014.

Build check:
  cd apps/lib/api-auth && go build ./...

═══════════════════════════════════════════════════════════════════════════
Section 3 — Implement inbound JWT+DPoP validation middleware
═══════════════════════════════════════════════════════════════════════════

middleware.go implements Middleware.ValidateInbound per ADR-0014.

What it validates (in order; first failure short-circuits):

  1. Authorization header present + starts with "Bearer "
     → fail: ErrInvalidToken
  2. Bearer token parses as JWS (use lestrrat-go/jwx/v2/jws)
     → fail: ErrInvalidToken
  3. Signature verifies against Keycloak JWKS
     - JWKS cache: in-memory, 1h TTL. On `kid` miss, refetch JWKS once.
       If still miss → fail: ErrInvalidToken.
     - JWKS HTTP client comes from Config (caller-provided so they can
       trust the mkcert local CA chain).
  4. `iss` matches Config.Issuer exactly → fail: ErrInvalidToken
  5. `aud` claim contains at least one entry from Config.AcceptedAudiences
     → fail: ErrAudienceMismatch
     (Per ADR-0014 § Per-API audience validation contract: backends configure
     a single accepted audience; multiple Middleware instances for multiple
     accept paths.)
  6. `exp` > now → fail: ErrTokenExpired
  7. `nbf` <= now (with 30s skew tolerance) → fail: ErrInvalidToken
  8. `iat` <= now (with 30s skew tolerance) → fail: ErrInvalidToken
  9. DPoP header present → fail: ErrDPoPMissing
 10. DPoP proof parses as JWS with embedded jwk → fail: ErrDPoPMismatch
 11. DPoP proof signature verifies with embedded jwk → fail: ErrDPoPMismatch
 12. DPoP `htm` matches request method → fail: ErrDPoPMismatch
 13. DPoP `htu` matches request URL canonicalized per RFC 9449 §4.3
     (lowercase scheme+host, drop default ports, strip query string)
     → fail: ErrDPoPMismatch
 14. DPoP `iat` within 60s of now → fail: ErrDPoPMismatch
 15. DPoP `jti` not in replay cache → fail: ErrDPoPMismatch
     (Cache is pluggable via interface — apiauth.ReplayCache. Tests use an
     in-memory impl; production wires the BFF's existing Valkey client.
     Cache TTL >= 60s + 30s skew = 90s minimum.)
 16. SHA-256 thumbprint of DPoP's embedded jwk equals the access token's
     `cnf.jkt` claim → fail: ErrDPoPMismatch
 17. After successful verification, store the DPoP `jti` in the replay cache
     with 90s TTL.

Return value on success: *Claims populated from the access token's claims.
SPIFFEID is extracted from the request's TLS peer cert if available
(via context.Context propagated from the mTLS terminator), else nil.

Wrap function:
  func (m *Middleware) Wrap(next http.Handler) http.Handler

The Wrap helper calls ValidateInbound, attaches *Claims to the request
context via a typed context key (apiauth.claimsKey{}), and forwards to next.
On any error, it writes the canonical HTTP status (per ADR-0014's error
mapping table) with body `{"error":"<short-string>"}` and emits one
audit-log line via Audit.LogHop (Section 5) before returning.

Test plan (middleware_test.go, table-driven):
  - Each error path above gets one row asserting both the returned error
    and the HTTP status when wrapped.
  - JWKS cache miss + refresh: assert exactly one extra HTTP call to JWKS.
  - DPoP replay: same jti twice within 60s → second rejected.
  - All happy-path claims propagated to context.

═══════════════════════════════════════════════════════════════════════════
Section 4 — Implement MintTokenForAudience (Client) + Q3 refresh-fallback
═══════════════════════════════════════════════════════════════════════════

client.go implements Client.MintTokenForAudience per ADR-0014.

Inputs (Config):
  - SessionStore: pluggable interface (apiauth.SessionStore) with
    Get(sessionID) (*Session, error) and Save(sessionID, *Session) error.
    Tests use in-memory; helloworld-bff wires Valkey.
  - AudienceList: []string — the BFF's static config (per Q2).
  - KeycloakTokenURL, KeycloakClientID, KeycloakClientPrivateKey
    (already used by Phase 6's BFF for private_key_jwt).
  - DPoPKey: *ecdsa.PrivateKey — the BFF's per-pod ECDSA key from Phase 6.
  - HTTPClient: *http.Client (caller-provided for CA-chain trust).

Logic (in order):

  1. If `aud` not in Config.AudienceList → return "", ErrAudienceNotConfigured
     immediately. Never touches Keycloak. (Per Q2: static config is the
     source of truth; runtime MUST NOT bypass it.)

  2. Look up session in SessionStore. Decode the cached access token.
     If `aud` claim contains the requested audience AND `exp` > now+30s
     → return the cached token. Done.

  3. Refresh path. POST to Config.KeycloakTokenURL with:
       grant_type=refresh_token
       refresh_token=<from session>
       client_id=<Config.KeycloakClientID>
       client_assertion=<private_key_jwt JWS>
       client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
       scope=<existing-scopes> + audience scope for the requested aud
       (the audience scope is the Keycloak client scope provisioned by
        infrastructure/keycloak/clients/<bff>.sh; Q2 makes this static.)

  4. Parse response:
       a) 200 OK with new access_token + refresh_token:
          - Verify the new access token's `aud` includes the requested audience
            (defense in depth — Keycloak should already enforce, but assert).
          - Update session in SessionStore with the new tokens.
          - Return the new access token.
       b) 4xx with `error=invalid_scope`, `error=invalid_grant`, or any
          other rejection: return "", ErrAudienceUnavailable.
          (The BFF's HTTP handler translates this into the Q3 fallback:
           401 + Set-Cookie clearing session + Location: /login.)
       c) 5xx or transport error: return "", ErrKeycloakUnreachable.

  5. After success, build a DPoP proof JWS over the request method+URL+
     access-token-thumbprint, signed by Config.DPoPKey. Return the access
     token to the caller. The caller is responsible for sending the access
     token + DPoP proof on the upstream request.

Verification work for ADR-0014 (do this step ONCE during implementation):

  In a temp shell, run a 10-minute curl test against the running Keycloak
  26.3.3 to determine which Q3 outcome is the default behavior:

    1. Pick an existing realm + confidential client (e.g. helloworld-bff
       in secforge-tenants).
    2. Get an initial token with a narrow scope set.
    3. Add a NEW audience scope to the client (kcadm: add an Optional
       client scope mapping Audience for the new aud).
    4. Refresh with `scope=<existing> <new-audience-scope>`.
    5. Check whether the new access token's `aud` claim contains the
       new audience (Q3 outcome (a)) or whether the refresh was rejected
       (Q3 outcome (b)).
    6. Capture the result + Keycloak's exact error response for (b).

  Open ADR-0014 and add an "## Observed Q3 behavior (2026-05-01)" section
  at the bottom — verbatim curl request, response, and one-line conclusion:
  "Outcome (a)/(b)" + the Keycloak version observed. The library handles
  both outcomes regardless; this just records reality so future operators
  know what to expect on a deploy.

  Tear down any test artifacts (kcadm-created scopes, throwaway clients
  tagged secforge.local/temporary=yes per the kcadm Path A pattern in
  Session 4 memory).

Test plan (client_test.go):
  - Audience not in AudienceList → ErrAudienceNotConfigured (table-driven).
  - Cached token still valid for requested aud → returned without calling
    Keycloak (assert HTTP call count == 0).
  - Cache miss + refresh succeeds → new aud in returned token.
  - Cache miss + refresh returns invalid_scope → ErrAudienceUnavailable.
  - Cache miss + refresh returns 502 → ErrKeycloakUnreachable.
  - Use a httptest.Server as the fake Keycloak. NOT a mock interface — we
    need to exercise the wire format.

═══════════════════════════════════════════════════════════════════════════
Section 5 — Implement audit log emitter (Audit) per Q4 schema
═══════════════════════════════════════════════════════════════════════════

audit.go implements Audit.LogHop per ADR-0014 + ADR-0012 § Q4 Resolution.

Schema (verbatim from ADR-0012 § Q4):

  {
    "request_id":         "<X-Request-ID; generated if absent>",
    "hop_index":          <int; BFF=1, first backend=2, ...>,
    "caller_workload_id": "spiffe://secforge.local/ns/<ns>/sa/<sa>",
    "caller_user_sub":    "<user's sub claim>",
    "target_audience":    "<aud claim of the token used for this hop>",
    "timestamp":          "<ISO8601 with milliseconds, UTC>",
    "endpoint":           "<HTTP method> <path>",
    "status":             <HTTP status code>
  }

Function signature:
  func (a *Audit) LogHop(req *http.Request, hopIndex int,
                          callerWorkloadID, callerUserSub,
                          targetAudience string, status int) error

Implementation:
  - Output sink is io.Writer from Config; default os.Stdout. Tests use a
    bytes.Buffer.
  - One log line per call. JSON, single-line, terminated by "\n".
  - Field order is fixed by the schema doc (use ordered map / explicit
    struct with json tags).
  - request_id resolution:
      a) If req.Header.Get("X-Request-ID") is non-empty → use it.
      b) Else generate a new ULID (use github.com/oklog/ulid/v2 — already
         a transitive dep via go-redis or jwx; check go.mod first).
      c) Set req.Header.Set("X-Request-ID", id) so downstream callers
         in the same process see it.
      d) Set the Response header too via req's response writer if
         available — out of LogHop's scope; the caller's middleware
         layer handles propagation. LogHop itself only reads.
  - timestamp: time.Now().UTC().Format(time.RFC3339Nano) truncated to
    millisecond precision.
  - endpoint: fmt.Sprintf("%s %s", req.Method, req.URL.Path) — query
    string deliberately omitted (PII safety; query strings often contain
    user identifiers).
  - LogHop MUST NOT block on the writer for >100ms. If the writer is
    slow (e.g. fluentd backed up), drop the line and increment a
    counter — an audit log line that hangs the request is worse than
    a missed one. (Document this trade-off in the function godoc.)
  - LogHop MUST NOT panic on any input.

Helper: ContextWithRequestID(ctx, id) and RequestIDFromContext(ctx)
for downstream callers that need to read or set the correlation ID
without the http.Request handle.

Test plan (audit_test.go):
  - Each schema field appears in the emitted JSON with the expected value.
  - Field order matches schema verbatim (regex on the emitted line).
  - request_id absent in input → generated, valid ULID, also written
    back to req.Header.
  - request_id present in input → preserved unchanged.
  - Slow writer (sleeping 200ms) → LogHop returns an error; line is
    dropped; counter increments. (Use a fake io.Writer that blocks.)

═══════════════════════════════════════════════════════════════════════════
Section 6 — Wire helloworld-bff as the first consumer
═══════════════════════════════════════════════════════════════════════════

helloworld-bff is the reference implementation. Other apps (Phase 9, 10)
copy this pattern.

Edits to apps/helloworld-bff/:

  1. go.mod: add `github.com/secforge/lib/api-auth v0.0.0` via a
     `replace github.com/secforge/lib/api-auth => ../lib/api-auth`
     directive (local module replace; we'll switch to a versioned
     dep when apps/lib/ gets its own git repo).

  2. main.go (or a new auth.go in the BFF):
     - Construct apiauth.Middleware with Config sourced from the BFF's
       existing env vars + the new BFF_AUDIENCE_LIST env var (already
       in deploy/02-deployment.yaml from Phase 6.10b — verify; add if
       missing).
     - Construct apiauth.Client using the same Keycloak config the BFF
       already loads from OpenBao.
     - Construct apiauth.Audit writing to os.Stdout (Promtail picks up).

  3. proxy.go: replace the existing manual "forward Authorization +
     DPoP" code path with calls to apiauth.Client.MintTokenForAudience(
     ctx, route.Audience). The route table (per-path → audience mapping)
     already exists from Phase 6's design — wire it through.

     On ErrAudienceUnavailable from MintTokenForAudience:
       - Clear the session cookie via Set-Cookie with Max-Age=0
       - Write a 401 with Location: /login
       - Emit one Audit.LogHop line tagged with status=401

     On ErrAudienceNotConfigured:
       - This is a config error, not a runtime user error. Emit a
         loud structured log AND fail the request with 500. Operator
         must add the audience to BFF_AUDIENCE_LIST and redeploy.

  4. New env var on the deployment:
       BFF_AUDIENCE_LIST=helloworld-api,authzen-facade
       (comma-separated; the library parses)
     Add to apps/helloworld-bff/deploy/02-deployment.yaml.

  5. Wire Audit.LogHop in:
       a) Inbound: at the entry of every protected handler (after
          ValidateInbound succeeds; once before the handler chain).
          hop_index=1, caller_workload_id=<this BFF's SPIFFE-SVID>,
          caller_user_sub=<from claims>.
       b) Outbound: in proxy.go BEFORE the upstream HTTP call,
          hop_index=2, caller_workload_id=<this BFF's SPIFFE-SVID
          again — caller is still us at this hop>, target_audience
          =<route.Audience>.
       c) Capture status code on the response and emit a third LogHop
          at hop_index=2 with the actual status — so a chain shows up
          in Loki as request → outbound-attempt → outbound-result.
          (Document: the audit log records intent at start-of-hop and
          outcome at end-of-hop; both are needed for forensics.)

  6. Smoke test: helloworld-bff still passes Phase 6's login flow
     end-to-end. Run the existing verification script
     (apps/helloworld-bff/deploy/apply.sh's curl smoke test).

═══════════════════════════════════════════════════════════════════════════
Section 7 — Verification
═══════════════════════════════════════════════════════════════════════════

Two layers: unit tests (fast, run in CI) and integration test (slower,
requires the running cluster).

Unit tests:
  - Each *_test.go file from Sections 3-5 must pass.
  - Run: cd apps/lib/api-auth && go test -race -count=1 ./...
  - Coverage target: >=80% line coverage. Use `go test -cover` to verify.
  - No flakes: run with -count=10 to catch ordering issues; must pass
    every time.

Integration test (apps/lib/api-auth/integration_test.go, build tag
`integration` so it doesn't run by default):

  1. Spin up the running cluster's BFF + AuthZEN-facade as the 2-hop chain.
  2. Generate a test request with a known X-Request-ID (e.g. e2e-int-test-1).
  3. POST through the BFF to AuthZEN-facade's evaluation endpoint.
  4. Wait 10s for log batching (Promtail flush interval).
  5. Query Loki via the Grafana datasource proxy:
       {request_id="e2e-int-test-1"}
  6. Assert:
       - Two log lines returned.
       - hop_index=1 line has caller_workload_id ending in
         "/sa/helloworld-bff" and target_audience="authzen-facade".
       - hop_index=2 line has caller_workload_id ending in
         "/sa/helloworld-bff" (still the BFF — it's the caller of
         hop 2, not the target) and target_audience matches.
       - Both lines share the same request_id.
       - Both lines have a status field populated.
  7. Tempo cross-check (sanity, not a hard pass criterion):
       Confirm a trace exists in Tempo with the same request_id (the
       X-Request-ID propagation should sync with the W3C traceparent
       Phase 7.6 already wired). If absent, log a warning but don't
       fail the test — Tempo correlation is a nice-to-have for this
       phase.

Wrap the integration test as a runnable script at
infrastructure/lib/api-auth/verify-integration.sh (mirrors the pattern
used by infrastructure/observability/verify-e2e.sh). Document in the
new runbook (next bullet).

Documentation deliverables:
  - docs/03-runbooks/api-auth-library.md — how to use the library:
    Middleware setup for a new backend API, MintTokenForAudience for
    a new outbound hop, common mistakes, troubleshooting.
  - docs/01-architecture/06-api-pattern.md — narrative description of
    the audience-at-login model. Cross-link to ADR-0012 + ADR-0014.

PLAN.md updates (mandatory dual-update per CLAUDE.md):
  - Quick-ref table row for 6b-1: ⬜ → ✅ (with date).
  - Detail block: status flips; add a Session-N summary line.
  - Bump "Last updated".
```

---

## Constraints (also enforced inside the prompt above; restated here for the operator)

- Library API surface fixed by ADR-0014 — do not invent new functions.
- 150-300 LoC total. If you exceed 400, stop and revisit.
- No global state. No env-var loading inside the library. No panics.
- Audit log emits on every protected request including denials.
- No mocks for the Keycloak refresh path — use `httptest.Server` to catch wire-format regressions.
- The Q3 10-minute curl verification (Section 4) is mandatory; ADR-0014 gets a verbatim observed-behavior addendum.

## Success criteria

- [ ] `apps/lib/api-auth/` builds; all unit tests pass with `-race -count=10`
- [ ] Coverage ≥ 80% line on `apps/lib/api-auth/`
- [ ] `helloworld-bff` rebuilt + redeployed; Phase 6 login smoke test still green
- [ ] Integration test: a 2-hop request through BFF → AuthZEN-facade produces two correlated log lines in Loki sharing one `request_id`
- [ ] ADR-0014 has an "## Observed Q3 behavior (2026-05-01)" section with the curl evidence
- [ ] `docs/03-runbooks/api-auth-library.md` published; `docs/01-architecture/06-api-pattern.md` written or updated
- [ ] PLAN.md quick-ref + detail block flipped to ✅; "Last updated" bumped
- [ ] Per ADR-0014's out-of-scope list: NO `ExchangeFor` function exists in the library; NO calls to Keycloak's RFC 8693 token-exchange endpoint anywhere in `helloworld-bff` or `apps/lib/api-auth/`

## Troubleshooting (library-specific; expand as 6b-1 actually runs)

**"JWKS validation fails intermittently"**
Keycloak rotates signing keys periodically. The library refreshes JWKS on `kid` miss. If failures persist, log the unknown `kid` from the inbound token + the `kids` from the cached JWKS — the diff identifies whether it's a stale cache or a genuinely unknown key.

**"DPoP `htu` mismatch"**
RFC 9449 §4.3: `htu` is the request URL with query string stripped, scheme/host lowercased, default ports omitted. Browser/proxy normalization differences bite here. Log both expected and actual `htu` on mismatch.

**"Replayed `jti` accepted"**
Replay-cache TTL must be ≥ DPoP `iat` window (60s) plus clock-skew tolerance. If TTL < window, an attacker could wait out the cache and replay.

**"`MintTokenForAudience` returns ErrAudienceUnavailable on every refresh"**
Keycloak rejected the expanded scope. Check that `infrastructure/keycloak/clients/<bff>.sh` provisioned the audience-scope mapping for that audience as an Optional scope on the BFF client (not Default — Optional means the client must request it explicitly). Re-run the script idempotently.

**"`ValidateInbound` returns ErrAudienceMismatch on the BFF's own callback"**
The BFF accepts session-tier tokens (after login) which carry `aud=<bff-id>`. Configure the Middleware that protects the BFF's `/api/*` routes with `AcceptedAudiences=[<bff-id>]`, NOT the downstream API audiences. The BFF mints downstream tokens via `Client.MintTokenForAudience` only for the upstream HTTP call to the backend, not for inbound validation against itself.

## What's next

[Phase 6b-2 — Outbound Secrets + Guardrails](./phase-06b-2-outbound-secrets.md) (independent; can run before or after this phase).

After both 6b halves: [Phase 7b — Post-6b-2 Monitoring Wire-up](./phase-07b-post-6b2-monitoring.md), then [Phase 9 — Hello World End-to-End](./phase-09-hello-world.md) which is the first non-BFF consumer of `apps/lib/api-auth/`.
