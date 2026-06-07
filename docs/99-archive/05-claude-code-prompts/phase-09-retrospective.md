> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 9 — Retrospective

> Phase 9 (Hello World End-to-End) closed 2026-05-04 with the 9.10.5 checkpoint passed and Phase 9.12 teardown + 9.13 verify-clean run. This document captures the **bugs that surfaced**, the **fixes that shipped**, and the **lessons that should travel forward into Phase 10** so they don't get re-discovered.
>
> Companion: [PLAN.md § Phase 9](../../PLAN.md) · [phase-09-hello-world.md](./phase-09-hello-world.md) · [10-helloworld-demo.md](../01-architecture/10-helloworld-demo.md)
>
> Last updated: 2026-05-04

---

## How to read this

For each bug:

- **Symptom** — what the operator saw
- **Root cause** — what was actually wrong
- **Fix** — file + commit
- **Phase 10 implication** — what to watch for in Project Tracker / Proposal Forge

The fixes are all already shipped (commits `66dc975`, `e532f91`). The point of this doc is the *implications* — Phase 10 BFFs are clones of helloworld-bff, so any bug here can resurface there if it's not understood.

---

## Library + config bugs (six of them, surfaced during 9.8 debugging)

### Bug 1 — `apps/lib/api-auth/client.go` minted client-assertion JWTs with `RS256` + no `kid`

**Symptom:** Keycloak rejected the BFF's `private_key_jwt` client assertion with `invalid_client`. Logs were unhelpful.

**Root cause:** The library was signing the client-assertion JWT with `RS256` and without a `kid` header. The Keycloak `helloworld-bff` client is configured `token.endpoint.auth.signing.alg=PS256`, and Keycloak's verifier indexes its registered keys by a **Keycloak-shaped `kid`** (DER-PKIX SHA-256 base64url over the public key). Without a matching `kid`, Keycloak doesn't know which key to verify against.

**Fix:** [apps/lib/api-auth/client.go](../../apps/lib/api-auth/client.go) now signs `PS256` and computes the Keycloak-shaped `kid` itself. Commit `66dc975`.

**Phase 10 implication:** Every Phase-10 BFF (project-tracker-bff, proposal-forge-bff, pm-bff) inherits this fix automatically by depending on the same library. **But** — when registering the new BFF clients in Keycloak, confirm the same `token.endpoint.auth.signing.alg=PS256` is set. The Phase 3 skeleton clients should already have it; verify before deploying.

---

### Bug 2 — `Middleware.ValidateInbound` accepted only `Authorization: Bearer`, not `DPoP`

**Symptom:** Backend rejected every BFF→backend request with 401 even though the BFF was happily forwarding a valid DPoP-bound token.

**Root cause:** RFC 9449 §7.1 (DPoP) **requires** that DPoP-bound tokens use the `DPoP` authentication scheme, not `Bearer`. The api-auth middleware's `ValidateInbound` was checking only `Authorization: Bearer ...` and rejecting `DPoP ...`.

**Fix:** [apps/lib/api-auth/middleware.go](../../apps/lib/api-auth/middleware.go) now accepts both schemes; behavior is identical except for the scheme keyword. Commit `66dc975`.

**Phase 10 implication:** Every Phase-10 backend that uses `apps/lib/api-auth/` for inbound validation gets this for free. If a backend writes its own validation (it shouldn't, but if it does), it MUST accept `DPoP` for DPoP-bound tokens.

---

### Bug 3 — BFF's `htu` was the in-cluster upstream URL, not the user-facing URL

**Symptom:** Every request from BFF → backend failed with `htu_mismatch` when the backend validated the DPoP proof. Direct curl from the operator's machine worked fine; only BFF-proxied traffic broke.

**Root cause:** The backend's `canonicalHTU` reads `X-Forwarded-Proto` / `X-Forwarded-Host` / `X-Forwarded-Port` to reconstruct the **public URL** the user originally requested (correct behavior under [ADR-0014](../02-decisions/0014-api-auth-library-design.md) and the F-ADR-3 audit finding). But the BFF's `proxyToBackend` was minting the DPoP proof using the **in-cluster upstream URL** (`http://helloworld-backend.app.svc.cluster.local:8080`) — those don't match.

**Fix:** [apps/helloworld-bff/proxy.go](../../apps/helloworld-bff/proxy.go) now mints DPoP proofs using `inboundHTU(r)` — the same canonicalization the backend uses. Commit `e532f91`.

**Phase 10 implication:** **Phase 10 BFFs MUST mint DPoP proofs against the public URL.** The fix is in `apps/helloworld-bff/proxy.go`; new BFFs cloned from helloworld-bff inherit the correct behavior. If you ever hand-write a DPoP-proof-minting code path elsewhere, use `inboundHTU(r)` (or its equivalent), not the upstream URL. The lesson generalizes: **anywhere a BFF and its backend independently canonicalize a URL, they must canonicalize identically.**

---

### Bug 4 — BFF `sessionTTL` interpreted `refresh_expires_in: 0` as "already expired"

**Symptom:** BFF sessions died one second after login. Cookie immediately invalidated; login loop.

**Root cause:** Keycloak returns `refresh_expires_in: 0` to indicate that the refresh token is an **offline token** (no expiry). The BFF's `sessionTTL` calculation was reading `RefreshExp == 0` as "expired at unix epoch" → calculated TTL of −∞ → clamped to 1 second.

**Fix:** [apps/helloworld-bff/session.go](../../apps/helloworld-bff/session.go) now treats `RefreshExp == 0` as the offline-token sentinel and falls back to `idleTTL`. Commit `e532f91`.

**Phase 10 implication:** Phase 10 BFFs reuse this session code. **Watch out for** other places we might be parsing OIDC / OAuth response fields with magic-zero meanings — `expires_in: 0` (also offline?), `not_before`, etc. Validate against RFC 6749 § 5.1 + Keycloak docs, not against intuition.

---

### Bug 5 — Keycloak `helloworld-bff` client lacked an `oidc-sub-mapper`

**Symptom:** Access tokens issued for the BFF didn't contain a `sub` claim. Backend's SpiceDB call (`CheckPermission` with `subject = sub`) returned an opaque error because SpiceDB regex-validated the subject and the empty string failed.

**Root cause:** Keycloak doesn't add `sub` to access tokens by default for some client types — there must be an explicit `oidc-sub-mapper`. The skeleton client provisioned in Phase 3 didn't have one.

**Fix:** Mapper added directly to the `helloworld-bff` client via kcadm (in the realm-bootstrap-bff-clients script — operator action). Lives in Keycloak state, no committed YAML.

**Phase 10 implication:** **Every Phase-10 BFF client needs the `oidc-sub-mapper` added.** The Phase 3 skeletons (`project-tracker-bff`, `proposal-forge-bff`, `pm-bff`) inherit the same defect. Add the mapper in the Phase 10.{N}.6 BFF bootstrap step, or amend [infrastructure/keycloak/realms/bootstrap-bff-clients.sh](../../infrastructure/keycloak/realms/bootstrap-bff-clients.sh) to apply the mapper for all four clients at once and re-run.

---

### Bug 6 — Keycloak `helloworld-api` audience mapper had to be per-client, not via client-scope binding

**Symptom:** Backend rejected access tokens because the `aud` claim didn't include `helloworld-api`. The "right" fix in OIDC is to bind a client scope that adds the audience; that approach silently failed.

**Root cause:** Binding a client scope to a `private_key_jwt`-authenticating client failed silently in our setup (Keycloak 26.3.3). Workaround: add an `oidc-audience-mapper` directly on the BFF client targeting `helloworld-api`.

**Fix:** Direct mapper applied via kcadm. No committed YAML; lives in Keycloak realm state.

**Phase 10 implication:** Same as Bug 5 — **every Phase-10 BFF gets a direct audience mapper**, not a client-scope binding. Whether this is a Keycloak bug or our config quirk is unresolved. If it's still broken in Keycloak ≥ 26.5, file an upstream issue. For now, work around it.

---

## SpiceDB orphan-lease bug (the big one)

### Symptom

SpiceDB was running fine for ~10 minutes after each `spicedb-datastore-refresher` CronJob run, then dying with `28P01` SASL auth failures. Cluster was effectively in a broken state for 11 of every 12 hours.

### Root cause (the actual one, not the bandaid)

OpenBao binds dynamic-credential leases to the **token that requested them**. When that auth token expires, **all child leases are revoked immediately**, regardless of the credential's own `default_ttl`.

The chain that fired:

1. `spicedb-datastore-refresher` CronJob fires, exchanges JWT-SVID for a BAO_TOKEN via `auth/jwt/login`.
2. OpenBao's JWT auth role had `token_ttl=10m`. The BAO_TOKEN was scoped to live 10 minutes.
3. With that token, the refresher mints a dynamic Postgres credential. Credential's own `default_ttl` is 14h.
4. 10 minutes later, the BAO_TOKEN expires. **OpenBao revokes the credential as a child lease.**
5. SpiceDB's connection pool starts getting auth failures because the credential is gone.

The earlier "fix" (commit `d42992f`, default_ttl 1h → 14h) treated a different symptom and made the cycle 14h-broken-window-per-day instead of 1h-broken-window-per-day.

### Fix (the real one)

`token_ttl > credential default_ttl`. JWT auth role's `token_ttl` bumped to 15h (covers the 14h credential lease + 1h headroom). Same pattern for `helloworld-backend` (1h credential lease → 90m token_ttl).

This is now codified as the canonical bootstrap: [infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh](../../infrastructure/openbao/configure-auth-jwt-spicedb-refresher.sh) and [infrastructure/helloworld/provision-db-and-bao.sh:189](../../infrastructure/helloworld/provision-db-and-bao.sh#L189). Commit `e532f91`.

### Phase 10 implication

**Every Phase-10 app that mints dynamic credentials via a SPIFFE-bound JWT auth role MUST set `token_ttl > credential default_ttl`.** Reviewing every new role definition is now part of the Phase 10.{N}.5 outbound-secrets step. If you're tempted to set a low `token_ttl` "for security" — that's the trap. Low token_ttl revokes the leases the workload depends on; the *security* boundary is the SPIFFE-ID, not the token lifetime.

The pattern lives in [ADR-0023](../02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md) (datastore_uri rotation context) and should probably get its own ADR — TODO: write **ADR-0025: JWT auth role token_ttl > credential default_ttl** so the rule is searchable, not buried in a refresher script.

---

## Side fixes that ride along

### Tempo memory limit 1Gi → 2Gi

OOM-killing under Grafana tag-load queries during Phase 9.9 observability checks. [infrastructure/observability/07-tempo-values.yaml](../../infrastructure/observability/07-tempo-values.yaml). **Phase 10 implication:** if Tempo OOMs again with multiple apps emitting traces, bump further or move to chunked retention.

### app-ns CPU quota 2 → 4 cores

`app` namespace was hitting CPU quota with helloworld BFF + backend + frontend running concurrently. [infrastructure/namespaces/namespaces.yaml](../../infrastructure/namespaces/namespaces.yaml). **Phase 10 implication:** Project Tracker + Proposal Forge each add 3 pods (BFF + backend + frontend). Quota will need another bump (probably to 8 cores) before both are deployed.

### nginx `sub_filter` injects per-request CSP nonce

The BFF's `strict-dynamic` CSP requires every `<script>` in the served HTML to carry a nonce that matches the response header. The frontend nginx config now uses `sub_filter` to inject per-request nonces at static HTML serve time. [apps/helloworld-frontend/nginx-default.conf](../../apps/helloworld-frontend/nginx-default.conf). **Phase 10 implication:** Project Tracker and Proposal Forge frontends also need this pattern. Vite's HTML output uses inline scripts that need nonces; copy the pattern wholesale.

### Container build: `docker save | ctr import`

Docker Desktop's containerd has a separate image store from the docker daemon. After a `docker build`, the image isn't visible to k8s.io containerd namespace. Fix: `docker save | docker exec ... ctr import -`. [apps/helloworld-bff/build.sh](../../apps/helloworld-bff/build.sh) (and same pattern in `helloworld-backend/build.sh`). **Phase 10 implication:** Phase 10 build scripts must use the same pattern. Operator-backlog #14 documents the related "ctr import reports total: 0.0 B" quirk — keep an eye on it.

---

## Wazuh-apid recovery (operational gotcha)

### Symptom

After a Wazuh manager pod restart, the Wazuh dashboard's "wait for dependencies" init blocks indefinitely. Looks like a startup race; isn't.

### Root cause

The `wazuh-apid` daemon stops after manager pod restarts and **is not auto-recovered**. The dashboard pod waits for it forever.

### Fix

Manual restart pattern: `kubectl exec -n wazuh wazuh-manager-0 -- /var/ossec/bin/wazuh-control restart`. No automated recovery yet.

### Phase 10 implication

**Wazuh isn't reliable as an audit-event sink yet.** The Phase 10 cutover plan should NOT depend on Wazuh seeing every login + mutation in real time until operator-backlog #17 (`client.keys` persistence) and #18 (manager-side decoders) close. Use Loki / Tempo for the audit checks instead.

---

## What worked well (for the record)

- **Sequencing.** Phase 9 hard-gated the cutover on a 9.10.5 checkpoint with **runtime evidence**, not just "tests pass." Caught Bug 4 (sessionTTL) which would have looked fine to a unit test. Phase 10 should keep this pattern.
- **Library consolidation in `apps/lib/`.** Bugs 1 and 2 fixed in one place propagate to every BFF/backend. The library was the right architectural call.
- **AuthZEN façade as a stable boundary.** Backend's SpiceDB integration through the façade isolated SpiceDB-specific quirks from the bug-hunt — Bug 5 surfaced as "subject is empty in the AuthZEN call," which led directly to the Keycloak mapper. If we'd hand-rolled SpiceDB calls in the backend, the empty subject would have been one more haystack to search.
- **Phase teardown.** 9.12 teardown + 9.13 verify-clean prevented the bug-laden helloworld state from leaking into Phase 10. Project Tracker starts on a clean cluster.

---

## Things to write next (queued)

1. **ADR-0025: JWT auth role token_ttl > credential default_ttl** — codify the SpiceDB orphan-lease lesson as a referenceable rule.
2. **Update Phase 10 prompt** — add "verify oidc-sub-mapper + audience-mapper present on the new BFF client" as a Phase 10.{N}.6 sub-step. Same for `htu` canonicalization in any new BFF.
3. **Open ADR or operator-backlog item for Wazuh-apid auto-recovery** — current manual-restart pattern is fragile and undocumented outside this retro.
