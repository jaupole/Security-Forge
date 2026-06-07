# ADR-0012: Token-exchange feasibility decision

**Status**: Accepted — NO-GO
**Date**: 2026-04-30
**Decision-makers**: Project owner

## Context

Phase 6b-1 planned to build the api-auth library against Keycloak's RFC 8693 `token-exchange` endpoint so the BFF could mint per-call audience-scoped tokens for downstream APIs. Keycloak ships token-exchange as a **preview** feature, with a known history of deviations from RFC 8693 in `subject_token_type` handling, `audience` parameter format, and `act` claim shape, and an API surface that can shift between minor versions.

Phase 6b-0 ran a 2-hour spike against the running Keycloak 26.3.3 instance to find out whether the deviations were documentable-and-wrappable (GO) or whether the surface was too unstable for a long-lived dependency (NO-GO). See [phase-06b-0-token-exchange-spike.md](../99-archive/05-claude-code-prompts/phase-06b-0-token-exchange-spike.md) for the spike protocol; spike scripts are at `infrastructure/keycloak/spike-token-exchange.sh` and `infrastructure/keycloak/spike-token-exchange-test.sh`.

The spike ran 2026-04-30. It exceeded its 2-hour budget; the spike prompt's own discipline ("if you hit 3 hours without a clear go/no-go, that itself is the answer; NO-GO") triggered.

## Decision

**NO-GO** on RFC 8693 token-exchange for the SecForge local-edition platform during Phase 6b-1.

Phase 6b-1 will pivot to **audience-at-login** per the spike doc's NO-GO definition: BFF requests the union of likely audiences at login, session is bound to all of them, and downstream APIs validate against their own `aud`.

Documented limitations of audience-at-login:

- Cannot mint tokens for audiences not anticipated at login. Adding a new downstream API requires the BFF's audience set to be updated and the user's session to be refreshed.
- Blast radius per token is larger — an all-audiences token leaked to an attacker grants access to every API in the audience set, not just one. DPoP mitigates this somewhat (proof-of-possession bound to the holder's key), but does not reduce it to per-call minimum-scope.
- No native audit-log "actor chain" via the RFC 8693 `act` claim. Actor identity in chained calls must be reconstructed from the request path and the calling workload's SPIFFE-SVID separately, in `apps/lib/api-auth/`'s audit log emitter.

## Findings

### 1. `token-exchange` requires `admin-fine-grained-authz` in tandem, not standalone

The phase prompt at `phase-06b-0-token-exchange-spike.md:41` listed only `--features=token-exchange`. That single flag is materially incomplete — without `admin-fine-grained-authz` also enabled, the `clients/<id>/management/permissions` endpoint (where per-client exchange policies are attached) returns "Feature not enabled". The phase prompt's instruction needs a fix-forward update; tracked as a follow-up.

### 2. `admin-fine-grained-authz` v1 and v2 both fail to satisfy runtime gating

Keycloak 26.3.3's `--features` help-all lists `admin-fine-grained-authz[:v1,v2]` as a recognized feature with two version variants. The spike attempted both:

- `admin-fine-grained-authz` (no suffix, defaults to v1): accepted in `KC_FEATURES` env var, confirmed by `kc.sh show-config`, but the runtime check at `org.keycloak.utils.ProfileHelper.requireFeature` (called from `ClientResource.getManagementPermissions:709`) still threw "Feature not enabled".
- `admin-fine-grained-authz:v2`: same outcome — accepted in env, confirmed by show-config, runtime still rejected.

The "Preview features enabled" startup log line listed only `dpop:v1, token-exchange:v1` in both cases, never including admin-fine-grained-authz despite its presence in the active configuration. Whether this is a Keycloak bug, an undocumented feature dependency, or a categorization quirk (admin-fine-grained-authz being a "default-disabled" rather than "preview" feature whose enable-message uses a different log path) was not resolved within spike budget.

v1 was not exhaustively verified after Plan A's apply — the simplest read is that both versions silently no-op, but a more thorough investigation might find a missing dependency. That investigation was out of scope per Path 1.

### 3. Per-pair authorization could not be configured within reasonable spike time

Configuring per-pair `(spike-bff, spike-api)` token-exchange authorization on Keycloak 26.3.3 was not achievable within the spike's wall-time budget. The "preview" status on `token-exchange` and `admin-fine-grained-authz` is materially load-bearing — the API surface is moving, runtime gating is inconsistent with configuration parsing, and error messages are not actionable (`[Feature not enabled]` with no guidance on which feature is missing or why a configured-and-loaded feature is being treated as disabled).

Three independent feature-flag fragilities surfaced:
- v1 form (`admin-fine-grained-authz`) silently rejected on apply ("unchanged" with no actual state change in the cluster, on at least one apply attempt)
- Both v1 and v2 forms accepted but no-op at runtime
- `tracing-service-name` and `tracing-resource-attributes` listed as UNAVAILABLE despite being core operator-managed options — separate issue but a similar "we say we support it but don't" signal

### 4. Client `private_key_jwt` authentication itself failed in 26.3.3

Independent of token-exchange, client_credentials auth as `spike-bff` using `private_key_jwt` (PS256) failed with `invalid_client: Unable to load public key`. The spike script set:
- `clientAuthenticatorType: client-jwt`
- `use.jwks.url: false`
- `use.jwks.string: false`
- `jwt.credential.public.key: <PEM-stripped base64 SPKI>`
- `token.endpoint.auth.signing.alg: PS256`

This layout was valid in older Keycloak versions. In 26.3.3, the runtime cannot decode the configured public key. Likely cause: the format changed to require `jwks.string` populated with a JSON JWKS document (with `use.jwks.string: true`), or some other attribute layout we did not have time to verify.

This is a separate fragility from token-exchange but compounds the "preview-feature-risky" signal: even basic client authentication mechanisms in 26.3.3 deviate from documented behavior in ways that require trial-and-error to surface.

## Mitigation requirements for Phase 6b-1's audience-at-login fallback

The audience-at-login pattern is established — every existing OIDC client in the `secforge-tenants` realm uses it (per Phase 3). Encode these guardrails in `apps/lib/api-auth/`:

- **Per-API audience validation** — already in plan; no change.
- **DPoP binding** — already in plan; no change. DPoP partially compensates for the larger blast radius by making an extracted token unusable without the BFF's private key.
- **Documented blast-radius implication** — `docs/01-architecture/06-api-pattern.md` must call out: a session token leak grants access to every API in the audience set. Mitigations: keep the audience set minimal per BFF (one BFF per app, not one BFF for all apps); short access-token lifetime (already 5 min in Phase 3); refresh-rotation with reuse detection (already enabled).
- **Actor chain in audit log** — since RFC 8693 `act` is unavailable, the api-auth library's audit log emitter reconstructs actor identity from: the request path (which BFF / which API hop), the calling workload's SPIFFE-SVID (verifies the workload identity at each hop), and a request-scoped correlation ID. Document this in `06-api-pattern.md` as the local-edition equivalent of the `act` chain.
- **Re-evaluation triggers** — see below.

### Open design questions (resolve at start of Phase 6b-1)

These four questions are surfaced by the audience-at-login pivot and not yet answered. Phase 6b-1 kickoff begins with a design conversation that resolves them; only then is `phase-06b-api-pattern.md` rewritten and the implementation begun.

- **Audience set scope:** per-app BFF requests its own app's API audiences only, OR shared BFF requests union of all audiences? Trade-off: smaller blast radius (per-app, narrower token leak impact) vs. simpler operations (shared, one audience-config code path). The "one BFF per app" mitigation in this ADR's main mitigation list assumes the per-app answer; this question makes that assumption explicit and contestable.
- **Audience discovery:** static list in BFF config, OR dynamic discovery from a service registry? Trade-off: explicit (auditable, version-controlled, one-step config drift detection) vs. emergent (no BFF redeploy when adding a downstream API; one less manual step). Affects how Keycloak per-API audience scopes are provisioned and synced.
- **Refresh-token flow:** with audience-at-login, the session refresh becomes load-bearing in a way it wasn't with token-exchange — every audience-set change requires a refresh. Document the refresh window (current session idle 30 min / max 12h from Phase 3 realm config) and rotation policy under this new constraint. Specifically: does adding a new audience require a forced re-login, or does the next refresh pick it up? Answer affects user-visible behavior on Phase 6b-1 deploys.
- **Audit log actor reconstruction:** without the RFC 8693 `act` claim, how does the audit log show cross-API call paths? Likely answer: reconstruct from `request_id` (correlation ID propagated across hops) plus the calling workload's SPIFFE-SVID at log-aggregation time. Specify the schema (which fields each hop emits) and the aggregation query (how a Loki/Tempo query reconstructs the chain from a single `request_id`). Decision must land in `apps/lib/api-auth/`'s audit log emitter contract.

## Re-evaluation criteria

Revisit token-exchange feasibility on any of:

- **Keycloak 26.4+ release**, if the release notes specifically mention stabilization of `token-exchange` and `admin-fine-grained-authz` (graduation from preview, fixed runtime gating, or documented dependency requirements).
- **Cloud-edition Keycloak** — managed Keycloak services (Red Hat SSO, Cloud-IAM, etc.) may pin to a more stable preview-feature surface, or have specifically validated the token-exchange path. The cloud migration is the natural re-evaluation point.
- **Compliance-driven audit requirements** — if any future Phase requires per-call actor-chain audit trails that the audience-at-login model cannot satisfy (e.g., regulatory requirement to demonstrate which BFF user / which workload made each downstream call, with cryptographic non-repudiation), token-exchange becomes worth re-spiking even if Keycloak's surface is still moving.
- **Phase 6b-1's library encounters API-shape needs that audience-at-login can't model** — e.g., a downstream API needing a different `sub` claim than the user's, or an A→B→C call chain where C must verify B's authority independently of A. If these become real, the audience-at-login pattern's limitations shift from theoretical to blocking and re-spiking is justified.

## Alternatives considered and rejected

### Audience-at-login (chosen as fallback)

Pros: works on stock Keycloak, no preview-feature dependency, every existing client in the realm already uses it.
Cons: documented above (cannot mint for unanticipated audiences; per-token blast radius larger; no native `act` chain).

### Per-API ID tokens via separate authorization_code flows

Pros: one token per API; minimum scope per call.
Cons: requires a separate browser-flow auth per API per session — heavyweight, introduces multi-tab UX issues, and doesn't compose with BFF→backend Tier-2 calls that don't have a browser. Not viable for our service-to-service pattern.

### Custom Keycloak SPI implementing RFC 8693 ourselves

Pros: full control over the request/response shape; no dependency on preview features.
Cons: defers RFC compliance work to us; SPI development surface in Keycloak 26.x is itself preview-stability-uncertain; substantial implementation cost (>5 days) for a workload that has no users yet. Defer indefinitely.

### Continued debugging within the spike (Path 2 in the spike retrospective)

Pros: cleaner protocol-flow data for the ADR.
Cons: would not change the GO/NO-GO outcome (the fine-grained-authz wall is dispositive); would exceed budget without producing reusable artifacts; honoring the spike prompt's 3-hour discipline.

## Rationale for stopping when we did

3+ hours into a 2-hour spike, three independent Keycloak fragilities encountered (token-exchange + admin-fine-grained-authz + private_key_jwt format), surface area moving across two preview features and one client-auth mechanism. The spike prompt's own discipline ("if you hit 3 hours without a clear go/no-go, that itself is the answer; NO-GO") triggered. Path 2 (cleaner protocol-flow data via private_key_jwt format fix) was offered and declined: refining rationale would not have changed the GO/NO-GO conclusion, and continued investigation would have exceeded budget without producing reusable artifacts.

Additionally, the `apiauth.ExchangeFor(ctx, audience)` library function this spike was meant to de-risk would have inherited every fragility found here — three Keycloak version-specific workarounds wrapped behind a single API call, each silently breaking on Keycloak version drift. The "preview" status really did mean what it says.

## Consequences

**Commits us to**:
- Audience-at-login as the Tier-2 (BFF→backend-API) and Tier-3 (API→API) authorization model in Phase 6b-1.
- Phase 6b-1's `apps/lib/api-auth/` library does NOT include `apiauth.ExchangeFor` or any RFC 8693 client.
- Phase 6b-1's Keycloak provisioning does NOT configure per-API audiences for token-exchange or per-pair exchange permissions; it does configure per-API audience scopes that BFF clients request at login.
- Per-call minimum-scope tokens are not available locally; the architecture doc must call this out and document the blast-radius implication.
- The spike scripts (`spike-token-exchange.sh`, `spike-token-exchange-test.sh`) are kept in-tree as historical artifacts of this decision. They are tagged "NO-GO; superseded by ADR-0012" in their header comments and are not run in any normal workflow.

**Preserves**:
- DPoP binding (already in Phase 6 / Phase 6b-1 plan; unaffected by token-exchange decision).
- Per-API audience validation (the `aud` check at each backend API; same code regardless of how the token was minted).
- The audit log schema; the actor field is populated via SPIFFE-SVID + request path rather than `act` claim.

**New risks**:
- Audience-at-login's larger per-token blast radius is now load-bearing. Mitigation requires discipline about keeping audience sets small (one BFF per app) and short token lifetimes — both already in plan.
- Re-evaluation triggers must be tracked in PLAN.md; without them, this NO-GO becomes silent permanent state and a future Keycloak version that fixes the surface will go un-reused.

**Cluster-state cleanup committed by this decision**:
- `admin-fine-grained-authz` is removed from the Keycloak CR's feature list (preview feature with no working code path that uses it; keeping it enabled would maintain blast radius for a feature we don't validate).
- `token-exchange` is removed from the Keycloak CR's feature list (audience-at-login does not use it; same reasoning).
- Spike clients (`spike-bff`, `spike-api`, `kcadm-spike`) are deleted at spike teardown.

## References

- [Phase 6b-0 spike prompt](../99-archive/05-claude-code-prompts/phase-06b-0-token-exchange-spike.md)
- [Phase 6b-1 api-auth library prompt](../99-archive/05-claude-code-prompts/phase-06b-api-pattern.md) — must be updated to reflect the audience-at-login pivot
- [PLAN.md — Phase 6b-0 entry](../../PLAN.md) — must be updated with NO-GO outcome and re-evaluation triggers
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [ADR-0011 — BFF single replica in local edition](./0011-bff-single-replica-local.md) — establishes the per-pod DPoP key model that this ADR's audience-at-login pivot leaves unchanged
- [ADR-0014 — API auth library design](./0014-api-auth-library-design.md) — captures the resolution of the four open design questions surfaced by this ADR
- Spike scripts: `infrastructure/keycloak/spike-token-exchange.sh`, `infrastructure/keycloak/spike-token-exchange-test.sh`

---

## Resolution (2026-05-01)

The four open design questions surfaced under [§"Open design questions (resolve at start of Phase 6b-1)"](#open-design-questions-resolve-at-start-of-phase-6b-1) above were resolved in a Phase 6b-1 kickoff design conversation. Decisions are recorded below verbatim and cross-referenced to [ADR-0014](./0014-api-auth-library-design.md), which captures the resulting library design contract.

### Q1 — Audience set scope: PER-APP BFF

Each app has its own dedicated BFF deployment with its own audience set in config. `helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `future-pm-bff` remain four separate Keycloak clients with non-overlapping audience scopes. **No shared BFF.**

This makes the "one BFF per app" mitigation in [§Mitigation requirements](#mitigation-requirements-for-phase-6b-1s-audience-at-login-fallback) load-bearing: the per-token blast radius is the audience set of one app's BFF, not the union of all apps. Adding a downstream API for app X does not expose app Y's session tokens.

### Q2 — Audience discovery: STATIC CONFIG IN BFF

Each BFF reads its audience set from values/env (e.g., `BFF_AUDIENCE_LIST="api.proposal-forge.svc,api.shared-auth.svc"`). Adding a new downstream API is a documented two-step operator workflow:

1. Add a Keycloak audience scope via `infrastructure/keycloak/clients/<bff>.sh`.
2. Add the audience to the BFF's values + redeploy.

Both steps are PR'd; both are auditable via git history. **No dynamic service-registry discovery.** The trade-off (explicit + auditable + version-controlled) was preferred over the emergent alternative because audience drift between Keycloak's authorized scopes and the BFF's configured set is the failure mode that audit-log review must surface — and a service registry hides that drift.

### Q3 — Refresh-token flow on audience change: TRY-EXPAND-FALLBACK-RELOGIN

When the BFF's audience set is updated and the BFF redeploys, existing user sessions stay valid. On next refresh, the BFF requests a `refresh_token` grant with the expanded scope set. Two outcomes:

- **(a)** Keycloak issues a new access token with the expanded `aud` claim. Done; user is unaware.
- **(b)** Keycloak rejects (`invalid_scope` or similar). The api-auth library catches this, returns a 401 with a `Set-Cookie` that clears the session, and the BFF redirects to `/login`. User sees "please sign in again."

The library handles both outcomes regardless. **Verification owed during Phase 6b-1 implementation:** a 10-minute curl test against the running Keycloak 26.3.3 to confirm whether (a) or (b) is the default. The observed behavior is recorded in [ADR-0014](./0014-api-auth-library-design.md) when 6b-1 runs.

### Q4 — Audit log actor reconstruction: SPIFFE+REQUEST-ID SCHEMA

Without RFC 8693's `act` claim chain, the audit log reconstructs cross-API actor identity from a fixed structured schema. Each hop emits one log line with these fields:

| Field | Type | Source |
|---|---|---|
| `request_id` | string (correlation ID) | Generated at ingress or BFF entry; propagated via `X-Request-ID` header |
| `hop_index` | integer | BFF=1, first backend=2, second backend=3, ... |
| `caller_workload_id` | SPIFFE-SVID URI | The workload making this hop, e.g. `spiffe://secforge.local/ns/app/sa/helloworld-bff` |
| `caller_user_sub` | string | Original user's `sub` claim from the OIDC token; propagated via `X-User-Sub` header from BFF onward |
| `target_audience` | string | The `aud` claim of the token used for this hop |
| `timestamp` | ISO8601 with milliseconds | Wall clock at hop |
| `endpoint` | string | HTTP method + path |
| `status` | integer | HTTP status code on response |

**Reconstruction:** a Loki query of `{request_id="abc-123"}` returns all hops; sort by `hop_index` gives the chain; SPIFFE-SVIDs identify each workload at each step; `caller_user_sub` identifies the original human actor across the entire chain. Tempo span linkage via the same `request_id` (W3C `traceparent` propagation already in Phase 7.6) gives a visual trace.

This schema is the local-edition equivalent of the `act` chain that token-exchange would have provided natively, and is realized by `apps/lib/api-auth/`'s audit log emitter contract — see [ADR-0014 § Audit log emitter](./0014-api-auth-library-design.md).
