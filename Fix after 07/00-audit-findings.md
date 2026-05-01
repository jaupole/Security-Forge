# 00 — Audit findings (post-Phase-7 remediation)

> **Audit date:** 2026-04-30 · **Cluster state:** Phase 7 Session 1 complete; Loki+Promtail live, Tempo+OTel installing. · **Scope:** entire project (PLAN.md, all phase prompts, all ADRs, architecture docs, runbooks, app code, live cluster).
>
> Each finding has a stable ID. The fix prompt at `01-fix-prompt.md` cites these IDs directly.

---

## Severity legend

- **CRITICAL** — blocks safe progress to Phase 8/9 or violates a CLAUDE.md bright-line rule
- **HIGH** — silent security or operability gap that will bite under load or at the compliance cutover
- **MEDIUM** — drift, missing ADR, underspecified control. Doesn't block work but should land before Phase 9
- **LOW** — cleanup, cosmetic, or low-impact documentation drift

---

## Section 1 — Execution-order bugs (the "phases out of order" complaint)

### F-ORD-1 · CRITICAL · Phase 6b-1 prompt is stale; cannot be run as-written
- **Phase introduced:** Phase 6b-0 produced ADR-0012 NO-GO; Phase 6b-1 was supposed to pivot to audience-at-login but the prompt was never rewritten.
- **Evidence:** `docs/05-claude-code-prompts/phase-06b-api-pattern.md` lines 1–22 explicitly say "Do not run this prompt as-is." `docs/02-decisions/0012-token-exchange-feasibility.md` lines 76–83 list four unresolved design questions.
- **Why it matters:** Phase 9 backend implementation depends on `apps/lib/api-auth/` from Phase 6b-1. Until Phase 6b-1 is rewritten and run, Phase 9 cannot start. PLAN.md does not surface this.
- **Secondary verification:** Confirmed — `apps/lib/` does not exist in the repo at all.
- **Fix scope:** Documentation. Resolve the four design questions (operator decision), rewrite Phase 6b-1 prompt to audience-at-login model. Out of scope for this fix package — flag-only. The fix prompt adds a clear "BLOCKING — design conversation required" callout to PLAN.md and Phase 9.

### F-ORD-2 · HIGH · Phase 9 prerequisites omit Phase 6b-1
- **Phase introduced:** PLAN.md line 487, `phase-09-hello-world.md` lines 99–100.
- **Evidence:** PLAN.md §9 "Prerequisites: Phases 1-7 complete (Phase 8 optional)" — but Phase 9.4's backend explicitly uses `apps/lib/api-auth/` from Phase 6b-1.
- **Why it matters:** A reader of PLAN.md alone would attempt Phase 9 without Phase 6b-1, then discover the missing library mid-implementation.
- **Fix scope:** Update PLAN.md §9 prerequisites + `phase-09-hello-world.md` header.

### F-ORD-3 · HIGH · Phase 7.0.b ordering inverted vs. its dependency
- **Phase introduced:** PLAN.md §Phase 7.0 line 391; `phase-07-observability.md` lines 77–80.
- **Evidence:** Phase 7.0.b (`realm_access.roles` debug) is described as a "carry-in to do BEFORE the observability stack design" but explicitly requires Phase 7.4 Loki to be live for verification. The phase prompt does not mention the 7.4 sequencing constraint.
- **Why it matters:** If 7.0.b runs before 7.4 (as the "carry-in" instruction implies), the debug work has no log surface to read.
- **Secondary verification:** Confirmed in PLAN.md text: "sequencing: must run AFTER 7.4 Loki goes live".
- **Fix scope:** `phase-07-observability.md` — explicit ordering note in 7.0.b. Phase 7 is in progress so this is documentation-only at this point.

### F-ORD-4 · HIGH · Phase 7b prerequisite on 6b-2 is buried
- **Phase introduced:** PLAN.md §7b line 412.
- **Evidence:** Phase 7b says "Prerequisites: Phase 7 ✅ AND Phase 6b-2 ✅" but Phase 6b-2 is ⬜ Not started. PLAN.md lists 7b in sequential reading order without a visible block marker.
- **Why it matters:** Reader of PLAN.md sequentially encounters 7b right after 7 and would attempt to start it, hitting failure mid-implementation.
- **Fix scope:** PLAN.md visual marker; `phase-07b-post-6b2-monitoring.md` hard-checkpoint at top.

### F-ORD-5 · HIGH · Phase 3 follow-up (kcadm-admin) scheduled after Phase 9 needs it
- **Phase introduced:** PLAN.md line 146 (Phase 3 follow-up scheduling).
- **Evidence:** Phase 3 follow-up "Scheduled for after Phase 7 completes" but Phase 9.2 requires reliable kcadm tooling to create three users (jason, alice, bob). kcadm 26.x has no `--otp` flag — the bug Phase 3 follow-up is meant to fix.
- **Why it matters:** Phase 9 user provisioning will fail or require manual UI-based workaround.
- **Fix scope:** PLAN.md scheduling correction OR explicit manual-workaround note in `phase-09-hello-world.md`. Operator decision.

### F-ORD-6 · MEDIUM · Carry-in laundering: Phase 7.0.a soak depends on Phase 7.7 dashboard (circular)
- **Phase introduced:** PLAN.md §7.0.a line 390.
- **Evidence:** "soak target = zero post-boot manual `kubectl delete pod` operations for 7 consecutive days, tracked via the platform-health Grafana dashboard's pod-restart panel (built in Phase 7.7)" — the verification surface for 7.0.a (which is supposed to gate 7.1) is itself built in 7.7, well after 7.1.
- **Why it matters:** Discipline broken; 7.0.a cannot be "verified before 7.1" if its verification dashboard doesn't exist until 7.7.
- **Fix scope:** `phase-07-observability.md` — relocate 7.0.a soak verification gate to a checkpoint between 7.7 and Phase 7 ✅ sign-off.

### F-ORD-7 · MEDIUM · Phase 6b-2 prerequisite on Phase 6b-1 not stated; both listed independent
- **Phase introduced:** PLAN.md §7b line 410 ("they're both schedulable independently").
- **Evidence:** Phase 6b-1 produces `apps/lib/api-auth/`; Phase 6b-2 produces `apps/lib/secrets/`. ADR-0015 says both libs live under `apps/lib/`. If 6b-2 runs first, it has to create the parent dir without conflicting with 6b-1's later additions.
- **Why it matters:** Minor — coordination on which phase creates `apps/lib/go.mod`. Solvable by convention.
- **Fix scope:** Add a one-line ADR clarification or a README in `apps/lib/` (created by whichever phase runs first).

### F-ORD-8 · MEDIUM · ADR slot 0016 referenced but not reserved
- **Phase introduced:** PLAN.md §Phase 3 follow-up line 123.
- **Evidence:** Text says "ADR slot is unallocated; check `ls docs/02-decisions/`" — slot reservation is a documented project rule (CLAUDE.md ADR-numbering section), but no stub exists.
- **Secondary verification:** Confirmed — `docs/02-decisions/0016-*.md` does not exist.
- **Fix scope:** This fix package writes ADRs 0016–0020 (see Section 3). ADR-0021 was reserved 2026-05-01 for Git initialization + commit-signing strategy (separate finding — see [docs/02-decisions/0021-git-initialization-and-commit-signing.md](../docs/02-decisions/0021-git-initialization-and-commit-signing.md)). The kcadm-admin Phase 3 follow-up ADR therefore moves to **0022**.

### F-ORD-9 · MEDIUM · Filename sort order is ambiguous
- **Phase introduced:** Project structure baseline.
- **Evidence:** `phase-06.10b-vso-and-secret-cleanup.md`, `phase-06b-0-token-exchange-spike.md`, `phase-06b-api-pattern.md`, `phase-06-istio-bff.md` do not lex-sort to execution order. Mixed dot-decimal + letter-suffix.
- **Why it matters:** Anyone reading `ls docs/05-claude-code-prompts/` gets a confusing order. New contributors mis-read sequence.
- **Fix scope:** Per operator decision in README.md. Default: do NOT renumber; add a navigation header to each phase doc. Renumbering is a follow-up cleanup, not in this package.

### F-ORD-10 · LOW · Phase 7 status drift between PLAN.md and phase doc
- **Phase introduced:** Phase 7 Session 1.
- **Evidence:** PLAN.md says "🟡 In progress (Session 1: 2026-04-30 — file work for 7.0.a/c, 7.1, 7.3, 7.4, 7.5...)". Phase 7 doc itself doesn't carry session-tracking — drift will accumulate.
- **Fix scope:** Add a status block at the top of each `phase-NN-*.md` mirroring PLAN.md, plus a one-line rule in the phase prompts README about who owns status truth.

---

## Section 2 — Architecture & ADR contradictions

### F-ADR-1 · HIGH · Passkeys vs TOTP — CLAUDE.md table is stale
- **Phase introduced:** ADR-0002 committed passkeys; ADR-0007 reverted to TOTP locally; CLAUDE.md table never updated.
- **Evidence:** `CLAUDE.md` line 48 — "Auth Factor | Passkeys + hardware keys for admin". `docs/02-decisions/0007-totp-instead-of-passkeys-locally.md` line 18 — "Do not configure WebAuthn / passkeys."
- **Why it matters:** A new contributor reads CLAUDE.md and assumes passkeys are deployed; tries to debug a passkey failure that doesn't exist because passkeys aren't there.
- **Fix scope:** Update CLAUDE.md table row to "TOTP (interim, ADR-0007); passkeys at production hardening."

### F-ADR-2 · HIGH · Token & credential lifetimes scattered, no consolidated source
- **Phase introduced:** Phase 3 (Keycloak), Phase 5 (OpenBao), Phase 2 (SPIRE).
- **Evidence:** Access token 5m mentioned in `01-iam-platform.md:135`. SPIRE X.509-SVID 1h, JWT-SVID 5m in `06-workload-identity.md:97`. OpenBao JWT-auth TTL 1h buried in `05-secrets-management.md:115`. No table linking these.
- **Why it matters:** Cache TTL bugs are silent. A backend assuming a 12h refresh window when Keycloak says 30m gets `invalid_grant` on refresh. Compliance cutover requires this table to be authoritative.
- **Fix scope:** Write ADR-0016. Cross-link from CLAUDE.md, all relevant architecture docs.

### F-ADR-3 · HIGH · DPoP `htu` canonicalization rule documented only for BFF
- **Phase introduced:** Phase 6.
- **Evidence:** `04-bff-pattern.md` lines 204–230 — detailed canonicalization rule for the BFF. No corresponding rule for backends or AuthZEN façade. Both will mint/validate DPoP proofs in Phase 9+.
- **Why it matters:** If the BFF and a backend disagree on `htu` (port included? trailing slash?), every DPoP-bound call fails with 401 silently. CLAUDE.md "local gotcha #3" warns about this exact issue.
- **Fix scope:** Extract the canonicalization rule to `docs/06-reference/dpop-htu-canonicalization.md`. Reference from BFF doc, future API auth lib (Phase 6b-1), and Phase 9.

### F-ADR-4 · MEDIUM · CSP nonce CSPRNG source unspecified
- **Phase introduced:** Phase 6.
- **Evidence:** `04-bff-pattern.md:281` — "fresh 16-byte random nonce per request" but no specification of `crypto/rand` vs. `math/rand`.
- **Why it matters:** A future engineer using `math/rand` makes nonces predictable; CSP bypass becomes possible.
- **Fix scope:** Update the architecture doc with explicit "MUST use `crypto/rand.Read`".

### F-ADR-5 · MEDIUM · Istio PERMISSIVE→STRICT cutover has no runbook
- **Phase introduced:** Phase 6.2 (interim PERMISSIVE).
- **Evidence:** `07-service-mesh.md:98–100` — "tightens to STRICT" but no procedure. Phase 7c references this work but the runbook is not written.
- **Why it matters:** When Phase 7c lands, the operator (or Claude) needs a stepwise procedure. Without it, breakage is likely (kubelet probes, openbao→postgres).
- **Fix scope:** Write `docs/03-runbooks/istio-peer-auth-tighten.md`. Reference from Phase 7c.

### F-ADR-6 · MEDIUM · NetworkPolicy default-deny is implicit, not stated as a design rule
- **Phase introduced:** Phases 1–6.
- **Evidence:** Each component doc has its own NetworkPolicy section, but no architecture-overview doc says "default-deny on every namespace." Verification (live cluster) confirms 8 of 8 app namespaces have it, but a new namespace could miss it without the rule.
- **Fix scope:** Add a section to `docs/01-architecture/00-overview.md`: NetworkPolicy contract.

### F-ADR-7 · MEDIUM · SpiceDB schema canonical source not declared in architecture doc
- **Phase introduced:** Phase 4.
- **Evidence:** `02-authorization.md:8` references `infrastructure/spicedb/schema.zed` but the inline schema in the doc is also full. No rule says which is canonical, no banner saying the doc is generated.
- **Why it matters:** Drift risk. A doc-only edit silently diverges from the applied schema.
- **Fix scope:** Add a banner to `02-authorization.md` declaring `infrastructure/spicedb/schema.zed` canonical; doc is reference.

### F-ADR-8 · MEDIUM · Missing ADR — Session expiry semantics
- **Phase introduced:** Phase 6 (BFF cookie design).
- **Evidence:** `04-bff-pattern.md:84` — `Max-Age` unset is a deliberate design choice, but only documented in the architecture doc (not as an ADR). Future engineer "fixes" persistent sessions by adding `Max-Age=24h` and silently breaks the design.
- **Fix scope:** Write ADR-0017.

### F-ADR-9 · HIGH · Missing ADR — DB multi-tenancy / RLS strategy
- **Phase introduced:** Should have been Phase 1 or Phase 9.
- **Evidence:** CLAUDE.md line 71 mandates RLS on every multi-tenant table. No ADR explains the strategy, no example RLS policy committed, no test approach.
- **Why it matters:** Phase 9+ apps will need this. Without an ADR, every app re-invents the pattern, badly.
- **Fix scope:** Write ADR-0018.

### F-ADR-10 · MEDIUM · Missing ADR — Secret distribution interface for first-class apps
- **Phase introduced:** ADR-0015 split operator-owned (VSO) from first-class (direct API) but did not define the first-class interface.
- **Evidence:** ADR-0015 says "direct-API via `apps/lib/secrets/`" but `apps/lib/` doesn't exist. No interface spec.
- **Fix scope:** Write ADR-0019. The fix prompt creates `apps/lib/secrets/` per this ADR.

### F-ADR-11 · MEDIUM · Missing ADR — OpenBao backup/restore/DR
- **Phase introduced:** Should have been Phase 5.
- **Evidence:** No runbook in `docs/03-runbooks/` covers OpenBao backup. `openbao-recovery.md` exists but covers seal-key recovery only.
- **Why it matters:** OpenBao holds every secret. Losing it = losing the platform.
- **Fix scope:** Write ADR-0020. Companion runbook deferred.

### F-ADR-12 · MEDIUM · Missing ADR — Image-signing key custody
- **Phase introduced:** Should have been Phase 1 or 2.
- **Evidence:** CLAUDE.md mentions "Cosign with local keys" but no ADR explains where the key is stored, how it's rotated, who has access.
- **Fix scope:** Operator decision — flag in README; not auto-written by this prompt because key custody is a real ops decision.

### F-ADR-13 · HIGH · Missing threat model — never created despite Phase 1 expectation
- **Phase introduced:** Phase 1 (per `docs/04-security/README.md` line 9 expectation, never delivered).
- **Evidence:** `docs/04-security/` contains only `README.md` — no `threat-model.md`. README itself was internally contradictory (line 9 said "Phase 1 (initial)", line 31 said "after Phase 6"). Six phases of security primitives were built without a written threat model.
- **Secondary verification:** Confirmed `ls docs/04-security/` returns only `README.md`. README contradiction fixed 2026-05-01 (line 9 reconciled to "after Phase 6 — see line 31").
- **Why it matters:** Without a threat model, security controls are designed against assumed threats rather than documented ones. Phase 9+ apps will retrofit to controls instead of being designed against threats. Every ADR in `docs/02-decisions/` is technically a partial threat-model fragment, but none of them roll up into a system-level STRIDE document. A senior security developer (the user) would expect this to exist.
- **Fix scope:** Section F of the fix prompt — interactive STRIDE walk-through with the user, written to `docs/04-security/threat-model.md`. Coverage required: all 7 CLAUDE.md bright-line rules, ADRs 0011–0019, the four open Phase 6b-1 design questions, the cold-boot Transit expiry. NOT in scope: Phase 9+ app-specific scenarios (stub for later); FedRAMP/CMMC/NIST control mapping (one paragraph cap).

---

## Section 3 — App-code coupling (compliance-cutover risk)

### F-APP-1 · HIGH · Keycloak `kid` derivation hard-coded in BFF
- **Phase introduced:** Phase 6 (helloworld-bff).
- **Evidence:** `apps/helloworld-bff/oidc.go:53–68` — `kid := base64url(SHA-256(DER-PKIX))`. Code comment explicitly notes this is Keycloak-specific (not RFC 7638).
- **Secondary verification:** Confirmed in source — comment at line 57: "Keycloak's kid for jwt.credential.public.key clients is base64url(SHA-256(DER-PKIX-encoded public key)). NOT RFC 7638 thumbprint."
- **Why it matters:** AWS Cognito, Okta, PingFederate all use different `kid` derivations. Compliance-cutover migration to Cognito = rewrite this function.
- **Fix scope:** Extract to `apps/lib/oidc/keycloak.go` behind a `Provider` interface. BFF imports the interface only. ~6h of refactor.

### F-APP-2 · HIGH · ID token claim binding hard-coded to Keycloak shape
- **Phase introduced:** Phase 6 (helloworld-bff).
- **Evidence:** `apps/helloworld-bff/proxy.go:94,96` — struct fields `PreferredUsername` (json:"preferred_username") and `SessionState` (json:"session_state").
- **Secondary verification:** Confirmed — these are Keycloak-specific claim names. Cognito's id_token uses `cognito:username`, no `session_state`.
- **Why it matters:** Same as F-APP-1 — direct rewrite at compliance cutover.
- **Fix scope:** Move claim parsing into `apps/lib/oidc/Provider.ParseClaims()` returning a vendor-neutral struct. Adapter for Keycloak today; second adapter at cutover.

### F-APP-3 · HIGH · SpiceDB `CheckPermission` not behind an interface
- **Phase introduced:** Phase 4 (authzen-facade).
- **Evidence:** `apps/authzen-facade/main.go:27–29` imports `authzed-go` directly; line 175 calls `s.client.CheckPermission(ctx, &v1.CheckPermissionRequest{...})` directly inside the evaluation handler.
- **Secondary verification:** Confirmed — only one call site, but the type `*authzed.Client` is on `server` struct (line 72), so a swap requires editing the struct + handler, not just an impl.
- **Why it matters:** Compliance migration to AWS Cedar or OPA = rewrite the evaluation handler. The whole point of the AuthZEN façade is that it's vendor-neutral at the API edge but currently leaks at the impl edge.
- **Fix scope:** Define `apps/lib/authzn/AuthZN` interface; SpiceDB adapter; swap call site to `s.authzn.Evaluate(...)`. ~4h.

### F-APP-4 · MEDIUM · OpenBao API paths hard-coded in BFF
- **Phase introduced:** Phase 5 (helloworld-bff openbao.go).
- **Evidence:** `apps/helloworld-bff/openbao.go:30–82` — hard-coded paths `/v1/auth/jwt/login`, `/v1/secret/data/...`, hand-rolled HTTP.
- **Why it matters:** Path coupling to OpenBao's KV v2 + JWT-auth API. AWS Secrets Manager has a different shape entirely.
- **Fix scope:** Wrap in `apps/lib/secrets/SecretBootstrapper` interface. ~3h.

### F-APP-5 · LOW · DPoP key lifecycle stays in-memory per pod
- **Phase introduced:** Phase 6.
- **Evidence:** `apps/helloworld-bff/main.go:87–92` — fresh ECDSA per pod boot, never persisted.
- **Why it matters:** This is fine for the local edition (ADR-0011 single-replica BFF). Cloud edition needs Valkey-stored per-session keys per architectural design. Flag-only — not a fix in this package.

### F-APP-6 · LOW · `apps/lib/` does not exist
- **Phase introduced:** ADRs 0014 + 0015 reference it as the home for shared libs.
- **Evidence:** `apps/` contains only `helloworld-bff/` and `authzen-facade/`.
- **Why it matters:** Phase 6b-1 and Phase 6b-2 are supposed to create subdirs here. The fix package creates the directory + minimal go.mod/README so the structure is established before those phases run.

---

## Section 4 — Live cluster drift

### F-CLU-1 · HIGH · OpenBao StatefulSet pods missing startupProbe
- **Phase introduced:** Phase 5.
- **Evidence:** `kubectl get pods -n openbao -o jsonpath=...startupProbe...` returns empty for openbao-0/1/2 and openbao-seal-0. Restart counts: openbao-1=6, openbao-2=6, openbao-seal-0=1 (all 13h ago, matching Docker Desktop wake/sleep).
- **Secondary verification:** Confirmed at audit time. **Important correction:** helloworld-bff and authzen-facade DO have startupProbes (`/ready` and `/readyz` HTTP probes). PLAN.md 7.0.a's "6 workloads" claim is stale — only the 4 OpenBao pods are missing them. Update PLAN.md accordingly.
- **Why it matters:** SPIFFE-CSI cold-boot race — pods that don't have a probe enter exponential backoff, JWT-SVIDs expire mid-retry, and recovery requires `kubectl delete pod`. Phase 7.0.a was supposed to fix this; it's still pending.
- **Fix scope:** Add startupProbe to OpenBao StatefulSets. The probe should check the SPIFFE socket, not just a TCP port.

### F-CLU-2 · HIGH · AuthorizationPolicy coverage incomplete
- **Phase introduced:** Phase 6 (only `app` ns covered).
- **Evidence:** `kubectl get authorizationpolicy -A` returns only 2 policies, both in `app`. `keycloak`, `spicedb`, `openbao`, `valkey`, `minio`, `observability`, `wazuh` are unprotected at the mesh layer.
- **Secondary verification:** Confirmed at audit time.
- **Why it matters:** Lateral movement between platform components is not prevented. Combined with PERMISSIVE PeerAuthentication (correct for Phase 6 / 7c-pending), the mesh provides minimal isolation today.
- **Fix scope:** Apply per-namespace AuthorizationPolicy (default-deny + explicit ALLOW for legitimate callers). Coordinate with Phase 7c to avoid double work — this fix package does the AuthzPolicies; Phase 7c does the PERMISSIVE→STRICT flip.

### F-CLU-3 · MEDIUM · OpenBao pods openbao-1, openbao-2 had recent restart spikes
- **Phase introduced:** Phase 5.
- **Evidence:** `restartCount=6` on openbao-1 and openbao-2; all 13h old (matching Docker Desktop wake event).
- **Why it matters:** Likely caused by F-CLU-1 (CSI cold-boot race). Should resolve when startupProbe is added. Verify after fix.
- **Fix scope:** Validation step after F-CLU-1. If restarts persist, investigate further.

### F-CLU-4 · LOW · `test-spire` namespace empty for 36+ hours
- **Phase introduced:** Phase 2 test workload.
- **Evidence:** `kubectl get pods -n test-spire` returns nothing; namespace age 36h.
- **Fix scope:** Operator decision. Default plan: delete it.

### F-CLU-5 · LOW · `wazuh` namespace empty pending Phase 7 Session 2
- **Phase introduced:** Phase 1 (namespace). Phase 7 (deferred deployment).
- **Evidence:** `kubectl get pods -n wazuh` returns nothing.
- **Fix scope:** Confirm Wazuh intent (deploy in Session 2 or defer indefinitely). If deferred, delete ns.

### F-CLU-6 · INFO · Kyverno `verify-image-signatures` in Audit (correct per ADR-0004)
- **Phase introduced:** Phase 1.
- **Evidence:** `validationFailureAction: Audit`. ADR-0004 explicitly documents this until a dedicated supply-chain phase runs.
- **Fix scope:** None. Reference-only flag in README.

### F-CLU-7 · INFO · PeerAuthentication PERMISSIVE (correct per Phase 7c plan)
- **Phase introduced:** Phase 6.
- **Evidence:** `kubectl get peerauthentication -n istio-system default` returns `mode: PERMISSIVE`.
- **Fix scope:** Phase 7c will tighten. This fix package adds the runbook (F-ADR-5) but does not flip the mode.

### F-CLU-8 · INFO · No ServiceAccount has `cluster-admin`
- **Phase introduced:** Phase 1 baseline.
- **Evidence:** `kubectl get clusterrolebinding -o json` — only `system:masters` and `kubeadm:cluster-admins` Groups bind to `cluster-admin`. No SA bindings.
- **Fix scope:** None — verifies CLAUDE.md bright-line rule is enforced.

### F-CLU-9 · INFO · No privileged containers except kube-proxy + spire-spiffe-csi-driver
- **Phase introduced:** Baseline.
- **Evidence:** Only privileged pods: `kube-system/kube-proxy-2z289` and `spire/spire-spiffe-csi-driver-9gkcw` (both expected — kernel uAPI access).
- **Fix scope:** None.

### F-CLU-10 · INFO · NetworkPolicy default-deny present in all 8 app namespaces
- **Evidence:** Verified.
- **Fix scope:** None for now. Convert the *practice* into a *rule* via F-ADR-6.

---

## Dependency graph (corrected execution order)

```
Phase 0 (Prerequisites) ✅
  └─→ Phase 1 (Foundation) ✅
        └─→ Phase 2 (SPIRE) ✅
              └─→ Phase 3 (Keycloak) ✅
                    ├─→ Phase 3 follow-up (kcadm-admin) ⬜  ← MUST run before Phase 9
                    └─→ Phase 4 (SpiceDB) ✅
                          └─→ Phase 5 (OpenBao) ✅
                                └─→ Phase 6 (Istio + BFF) ✅
                                      ├─→ Phase 6b-0 (Token-exchange spike) ✅ NO-GO → ADR-0012
                                      ├─→ Phase 6.10b (VSO + secret cutover) ✅
                                      ├─→ Phase 6b-1 (API Auth Library) 🟥 BLOCKED on design conv. → MUST ✅ before Phase 9
                                      ├─→ Phase 6b-2 (Outbound secrets pattern) ⬜
                                      └─→ Phase 7 (Observability) 🟡
                                            ├─→ 7.0.a (SPIFFE-CSI startupProbe) ← in Fix-after-07 too (F-CLU-1)
                                            ├─→ 7.0.b (realm_access.roles debug) ← MUST be after 7.4 Loki
                                            ├─→ 7.0.c (OIDC CLI redirect URI)
                                            └─→ 7.1–7.7 (stack)
                                                  ├─→ Phase 7b (Post-6b-2 monitoring) ⬜  ← BLOCKED on Phase 6b-2
                                                  ├─→ Phase 7c (SPIRE-as-CA + STRICT) ⬜
                                                  └─→ Phase 7d (Rotation + housekeeping) ⬜
                                                        ↓
                                                ☆ Fix-after-07 (this package) ☆
                                                        ↓
                                                  ├─→ Phase 8 (Teleport) ⬜ optional
                                                  └─→ Phase 9 (Hello World) ⬜
                                                          [needs: 1-7 ✅, 6b-1 ✅, 3-follow-up ✅]
                                                        └─→ Phase 10 (Integrate apps) ⬜
                                                              [needs: 1-9 ✅, 6b-2 ✅]
                                                              └─→ Phase 11 (Develop apps) ⬜
```

**Critical-path blockers for Phase 9:**
1. Phase 7 fully ✅ (Session 2 work + 7.0.a soak verified)
2. Phase 6b-1 design conversation + prompt rewrite + execution
3. Phase 3 follow-up (kcadm-admin)
4. This Fix-after-07 package (interface refactors + AuthzPolicies)

---

## Status truth table (PLAN.md vs reality)

| Phase | PLAN.md | Phase doc | Cluster reality | Blocker |
|-------|---------|-----------|----------------|---------|
| 0 | ✅ | ✅ | ✅ | — |
| 1 | ✅ | ✅ | ✅ | — |
| 2 | ✅ | ✅ | ✅ | — |
| 3 | ✅ | ✅ | ✅ | F-ORD-5 |
| 3 follow-up | ⬜ | n/a | n/a | F-ORD-5, F-ORD-8 |
| 4 | ✅ | ✅ | ✅ | F-APP-3 (refactor scoped here) |
| 5 | ✅ | ✅ | ✅ (with restart history) | F-CLU-1 |
| 6 | ✅ | ✅ | ✅ | F-APP-1, F-APP-2, F-APP-4, F-CLU-2 |
| 6b-0 | ✅ NO-GO | ✅ | n/a | — |
| 6b-1 | ⬜ | 🟡 (stale prompt) | n/a | F-ORD-1 |
| 6b-2 | ⬜ | ⬜ | n/a | — |
| 6.10b | ✅ | ✅ | ✅ | — |
| 7 | 🟡 | 🟡 | partial | F-ORD-3, F-ORD-6, F-CLU-1 |
| 7b | ⬜ | ⬜ | n/a | F-ORD-4 |
| 7c | ⬜ | ⬜ | n/a | F-ADR-5 (runbook) |
| 7d | ⬜ | ⬜ | n/a | — |
| 8 | ⬜ | ⬜ | n/a | optional |
| 9 | ⬜ | ⬜ | n/a | F-ORD-2, F-ORD-5, F-ORD-1 |
| 10 | ⬜ | ⬜ | n/a | Phase 9 |
| 11 | ⬜ | ⬜ | n/a | Phase 10 |

---

## Findings summary

| Section | Critical | High | Medium | Low | Info |
|---------|---------:|-----:|-------:|----:|-----:|
| Execution order | 1 | 4 | 4 | 1 | — |
| Architecture / ADRs | — | 5 | 7 | — | — |
| App-code coupling | — | 3 | 1 | 2 | — |
| Live cluster | — | 2 | 1 | 2 | 5 |
| **Total** | **1** | **14** | **13** | **5** | **5** |

---

## Headline takeaways

1. **Phase 9 cannot start until 4 things land**: Phase 7 ✅, Phase 6b-1 design + execution, Phase 3 follow-up, and this fix package's interface refactors.
2. **The single biggest compliance-cutover risk** is the Keycloak coupling in `helloworld-bff` (F-APP-1, F-APP-2). Fix it before Phase 9 builds more code on top of those patterns.
3. **The single biggest local-stability bug** is the missing OpenBao startupProbes (F-CLU-1). Manual `kubectl delete pod` after every Docker Desktop restart is unsustainable.
4. **The CLAUDE.md "things that should never happen" list is being upheld** — no SA has cluster-admin, no privileged containers in app namespaces, NetworkPolicy default-deny is universal. Nothing in this audit is a bright-line violation. Most issues are "control documented but not implemented at the code/config level."
5. **The phase-ordering complaint is real but mostly cosmetic**: there is one real ordering inversion (F-ORD-3, 7.0.b before 7.4) and one circular dependency (F-ORD-6, 7.0.a soak depends on 7.7 dashboard). The rest is filename sort confusion (F-ORD-9) and missing prerequisite cross-references — solvable by navigation headers.
