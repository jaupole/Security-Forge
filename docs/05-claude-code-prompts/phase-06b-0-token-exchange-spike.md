# Phase 6b-0 — Token-exchange spike

**Status:** ✅ Complete (2026-04-30) — **NO-GO**. See [ADR-0012](../02-decisions/0012-token-exchange-feasibility.md). Phase 6b-1 pivots to audience-at-login.

**Estimated time:** 2 hours (actual: 3+; the spike prompt's own NO-GO trigger fired)

**Prerequisites:** Phase 3 (Keycloak) running. No code dependency on Phase 6 — this can be run any time before Phase 6b-1 starts.

---

## Outcome (2026-04-30) — NO-GO

This document is retained as the spike protocol template. If a re-evaluation trigger fires (Keycloak 26.4+ stabilization, cloud migration, compliance-driven audit needs — see ADR-0012 §"Re-evaluation criteria"), re-run this protocol with the **fixes documented inline below** and update ADR-0012 with a new findings section.

**What broke (full detail in ADR-0012 §"Findings"):**

1. The `--features=token-exchange` line at §6b-0.1 below is **insufficient on its own**. Keycloak 26.x also requires `admin-fine-grained-authz` for the `clients/<id>/management/permissions` endpoint where per-pair exchange policies are attached. **Fix-forward**: a re-spike must enable both: `--features=recovery-codes,dpop,token-exchange,admin-fine-grained-authz`.
2. Even with both flags enabled (and confirmed in `KC_FEATURES` env + `kc.sh show-config`), the `admin-fine-grained-authz` runtime gating at `ClientResource.getManagementPermissions:709` was not satisfied — both v1 and v2 forms appeared to no-op. A future re-spike must verify the feature is actually loaded before proceeding past §6b-0.2.
3. Independent fragility: `private_key_jwt` client auth at §6b-0.3 step 1 failed with `invalid_client: Unable to load public key` using the documented `jwt.credential.public.key` + `use.jwks.string=false` layout. The format appears to have changed in Keycloak 26.x. A future re-spike must verify the basic client_credentials flow works before attempting token-exchange — possibly by populating `jwks.string` with a JSON JWKS document instead.

**Cluster state after teardown:**
- `token-exchange` and `admin-fine-grained-authz` REMOVED from the Keycloak CR's feature list (per ADR-0012's blast-radius reasoning).
- Spike scripts retained in-tree as historical artifacts: `infrastructure/keycloak/spike-token-exchange.sh`, `infrastructure/keycloak/spike-token-exchange-test.sh`. They reference deleted clients and disabled features; do not run as part of any normal workflow.
- A re-spike re-enables both feature flags via the Keycloak CR, re-creates the `kcadm-spike` master-realm service-account client (the spike scripts authenticate as it via `KCADM_CLIENT_SECRET`; the user/password+TOTP path used in the original prompt does not work on kcadm 26.x), and re-runs the protocol below.

---

## Goal of this phase

De-risk Keycloak's preview `token-exchange` feature **before** Phase 6b-1 writes a Go library against it. Keycloak's RFC 8693 implementation is known to deviate in places (`subject_token_type` handling, `audience` parameter format, `act` claim shape). "Preview" status also means the API surface can shift between minor versions. Find this out in 2 hours, not after writing 11 unit tests.

If the spike reveals a serious deviation: pivot Phase 6b-1 to "audience-at-login" with documented limitations. Either path is fine; the cost is finding out early.

---

## What you (the human) need to do first

1. Confirm Keycloak (Phase 3) is running and you can hit the admin console.
2. Decide whether to spike against the existing Keycloak instance or a throwaway one. Existing is fine — the spike does not modify production state if you tear down the test clients afterward.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're running a 2-hour spike to de-risk Keycloak's preview token-exchange feature before Phase 6b-1 commits to RFC 8693. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-06b-0-token-exchange-spike.md before doing anything.

Goal: prove the token-exchange flow works end-to-end against our Keycloak, document any deviations from RFC 8693, decide go/no-go.

## Phase 6b-0.1 — Enable the feature flag

Token-exchange is preview. Update the Keycloak Custom Resource's feature list:

  --features=recovery-codes,dpop,token-exchange,admin-fine-grained-authz

NOTE (post-2026-04-30 spike): the `admin-fine-grained-authz` flag is REQUIRED in addition to `token-exchange` — without it, the `clients/<id>/management/permissions` endpoint where per-pair exchange policies are attached returns "Feature not enabled". This was the gap that caused the 2026-04-30 spike to fail. Both flags must be on.

Apply, wait for rollout, verify BOTH flags are active in the running pod by checking the env (more reliable than the "Preview features enabled" log line, which does not enumerate non-Preview features):

  kubectl exec -n keycloak keycloak-0 -c keycloak -- env | grep KC_FEATURES

Expect: `KC_FEATURES=recovery-codes,dpop,token-exchange,admin-fine-grained-authz`

## Phase 6b-0.2 — Configure minimal test clients

In the `secforge-tenants` realm via kcadm:

- One BFF-shaped client `spike-bff` (client-jwt, PAR + DPoP + PKCE, redirect URI any localhost path)
- One API-shaped client `spike-api` (no redirect, just an audience target)
- Configure fine-grained exchange permission: `spike-bff` may exchange tokens for `aud=spike-api`

Use idempotent kcadm scripts; commit them to `infrastructure/keycloak/spike-token-exchange.sh`. The clients will be deleted at the end of the spike — the script is committed for future reproduction, not retention.

## Phase 6b-0.3 — Drive the flow end-to-end

Write `infrastructure/keycloak/spike-token-exchange-test.sh`:

1. Authenticate `spike-bff` with private_key_jwt to obtain an initial access token (subject token)
2. Call the token endpoint with:
   - `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`
   - `subject_token=<initial token>`
   - `subject_token_type=urn:ietf:params:oauth:token-type:access_token`
   - `audience=spike-api`
   - `requested_token_type=urn:ietf:params:oauth:token-type:access_token`
3. Decode the resulting JWT (jq + base64) and dump its claims
4. Verify:
   - `aud` contains `spike-api` (and ONLY `spike-api`, not the original)
   - `sub` is preserved from the original
   - `act` claim chain is present and shaped per RFC 8693 §4.1 (nested `act.sub` = `spike-bff`)
   - Exp is short (5 min)
   - Token is signed by the realm's RS256 key

## Phase 6b-0.4 — Document deviations

In `docs/02-decisions/0012-token-exchange-feasibility.md` (create the ADR if not yet present, otherwise add a "Token-exchange spike findings" section), capture:

- Exact request shape Keycloak accepts (parameter names, content-type, anything that deviates from RFC 8693 §2.1)
- Exact response shape (parameter names, anything missing or extra)
- `act` claim structure as actually emitted (RFC 8693 §4.1 specifies nested `act` with `sub` and optional further nesting; record what Keycloak actually does)
- Whether `audience` accepts a single value, multiple values, or both
- Whether `requested_token_type` is required or inferred
- Any error responses the library will need to handle specifically (e.g. `invalid_target` for unauthorized audience pairs)
- DPoP binding: does the exchanged token bind to the requester's DPoP key automatically, or does the request need to carry a DPoP proof header?

## Phase 6b-0.5 — Go/no-go decision

Append a "Decision" section to ADR-0012 with one of:

**GO**: token-exchange works as expected. Phase 6b-1 implements `apiauth.ExchangeFor(ctx, audience)` against this exact request/response shape. Document deviations as constants in the library so future Keycloak version drift is observable in one place.

**NO-GO**: token-exchange is too unstable / deviated / preview-feature-risky. Phase 6b-1 falls back to "audience-at-login": BFF requests the union of likely audiences at login, session is bound to all of them, downstream APIs validate against their own `aud`. Document the limitations: cannot mint tokens for audiences not anticipated at login, blast radius per token is larger.

Either decision is valid. Bias toward GO if the deviations are documentable and the library can wrap them; bias toward NO-GO if Keycloak's behavior is non-deterministic or contradicts what the architecture doc assumed.

## Phase 6b-0.6 — Tear down

- Delete `spike-bff` and `spike-api` clients (the kcadm script is committed; the runtime state is not needed)
- Leave the `--features=token-exchange` flag enabled — Phase 6b-1 will use it
- Confirm no stray secrets, tokens, or test data remain in shell history or working files

## Constraints

- Total wall time target: 2 hours. If you hit 3 hours without a clear go/no-go, that itself is the answer (NO-GO; the surface is too rough)
- Do not write any production library code in this spike — the goal is decision data, not implementation
- Spike script and test script committed and idempotent
- ADR captures the decision and rationale, not just the test output
```

---

## Success criteria

- [ ] `spike-token-exchange.sh` and `spike-token-exchange-test.sh` committed and idempotent
- [ ] End-to-end token-exchange flow drives a real `aud=spike-api` token from a `spike-bff` subject token
- [ ] `aud`, `sub`, `act` claims captured and documented in ADR-0012
- [ ] Deviations from RFC 8693 documented (or explicit "no deviations observed")
- [ ] Go/no-go decision recorded in ADR-0012
- [ ] Test clients torn down; feature flag remains enabled

---

## Troubleshooting

### "invalid_target" on every exchange attempt
Fine-grained permission for the `(spike-bff, spike-api)` pair is not configured. Check via `kcadm get clients/<id>/management/permissions`. Permissions are per-direction; symmetry is not assumed.

### "unsupported_grant_type"
Either the feature flag isn't active (verify in pod logs: `Preview feature enabled: token-exchange`) or the token endpoint is being hit with the wrong client. Token-exchange is enabled per-realm via the feature flag; per-client permissions gate which exchanges are allowed.

### `act` claim absent
Keycloak's older versions emitted impersonation tokens without the actor chain. Check Keycloak version (we run 26.3.3, which should support it). If absent, document — it changes the audit story for Phase 6b-1.

### Decoded token fails signature verification
Keycloak signs exchanged tokens with the same realm key as login tokens. Verify `kid` in the JWT header matches a key from `https://auth.secforge.local/realms/secforge-tenants/protocol/openid-connect/certs`.

---

## What's next

[Phase 6b-1 — API Auth Pattern](./phase-06b-api-pattern.md) — implements the library against whatever the spike decision was.
