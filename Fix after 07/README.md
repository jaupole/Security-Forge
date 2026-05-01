# Fix after 07 — post-Phase 7 remediation package

> **Purpose:** consolidated remediation for issues introduced in Phases 0–6 (and surfaced during Phase 7 work) that should have been corrected earlier. One audit, one fix prompt, run after Phase 7 fully completes.

---

## When to run this

**After Phase 7 is fully ✅** — meaning all of:

- Phase 7.0.a (SPIFFE-CSI startupProbe soak) signed off
- Phase 7.0.b (`realm_access.roles` debug) complete
- Phase 7.0.c (OIDC CLI redirect URI) applied
- Phase 7.1–7.6 stack live and verified
- Wazuh deployment in `wazuh` ns (currently empty)
- Phase 7.7 platform-health dashboard live

**Do NOT run this prompt while Phase 7 is still 🟡.** Several fixes here depend on Loki being live for verification, and several findings overlap with Phase 7.0 carry-ins — running too early creates merge conflicts with Phase 7's own work.

**Phase 7b / 7c / 7d are NOT prerequisites.** This package is independent of those — they can run before, after, or in parallel with this fix package, since they touch different surfaces (7b: secret-guardrail monitoring; 7c: PERMISSIVE→STRICT mTLS cutover; 7d: rotation/housekeeping). However, this package does add navigation pointers to those phase docs, so if you reorder, re-grep for cross-references.

---

## What's in this folder

| File | Purpose |
|------|---------|
| `README.md` | This file |
| `00-audit-findings.md` | Severity-ranked findings from the four-agent audit. Reference only — paste-able evidence for each finding. The fix prompt cites this by ID (F-NN). |
| `01-fix-prompt.md` | The Claude Code prompt. Paste the contents into a fresh session. It does code/config fixes, doc updates, and bakes phase-navigation pointers into the existing PLAN.md and phase prompt docs. |

---

## How to run the fix prompt

1. **Confirm prerequisites** above. If anything in Phase 7 is still 🟡, stop.
2. **Open a fresh Claude Code session** in the project root.
3. **Paste the entire contents of `01-fix-prompt.md`** as your message. Don't paste the audit findings — the fix prompt references them by ID and reads `00-audit-findings.md` itself.
4. **Approve tool calls as Claude works.** The prompt is structured to ask before destructive operations (file deletions, kubectl deletes, manifest replacements with non-trivial diffs).
5. **Expect this to take 4–8 hours of session time** spread over 2–3 sessions. The prompt has natural stop points after each "section."

---

## What gets changed

### Code (apps)
- `apps/lib/secrets/` created — wraps OpenBao HTTP API behind a `SecretBootstrapper` interface
- `apps/lib/oidc/` created — wraps Keycloak-specific `kid` derivation + claim binding behind a `Provider` interface
- `apps/lib/authzn/` created — wraps SpiceDB `CheckPermission` behind an `AuthZN` interface
- `apps/helloworld-bff/*.go` — refactored to use the new lib packages
- `apps/authzen-facade/main.go` — refactored to use the new lib packages

### Cluster
- `startupProbe` added to OpenBao StatefulSets (openbao-0/1/2, openbao-seal-0)
- AuthorizationPolicy default-deny + namespace-scoped allows added to `keycloak`, `spicedb`, `openbao`, `observability`, `minio`, `valkey` namespaces
- `test-spire` namespace cleanup decision (delete or document)

### Documentation
- New ADRs: 0016 (token & credential lifetimes), 0017 (session expiry), 0018 (multi-tenancy/RLS), 0019 (secret-distribution interface), 0020 (OpenBao DR)
- ADRs 0002 & 0007 — passkey vs TOTP reconciliation in CLAUDE.md stack table
- `docs/01-architecture/04-bff-pattern.md` — CSP nonce CSPRNG specification, DPoP `htu` canonicalization extracted to standalone reference
- `docs/03-runbooks/istio-peer-auth-tighten.md` — new runbook (referenced by Phase 7c)
- `docs/06-reference/dpop-htu-canonicalization.md` — extracted from BFF doc
- `docs/06-reference/migration-keycloak-to-cognito.md` — compliance-cutover playbook
- `PLAN.md` — status truth corrections, prerequisite fixes, dependency graph, navigation pointers
- All `phase-*.md` docs — phase-navigation header (prev / next / depends-on) added

### What is intentionally NOT changed
- Phase numbering. The audit recommended renumbering for sort order; we keep the existing scheme and add a navigation header instead. Renumbering touches every cross-reference in the project and is a separate, optional cleanup.
- Phase status flags except where the audit found a documented-vs-actual mismatch.
- Anything Phase 7c is going to touch (mTLS PERMISSIVE→STRICT). The fix prompt explicitly avoids that surface.

---

## Risk and rollback

Every cluster change in the fix prompt is idempotent and reversible:
- Manifest changes go via `kubectl apply -f` against new files in `infrastructure/`. Roll back via `kubectl apply -f <prior-version>` or `git revert`.
- Code refactors are wrapper-add-then-call-site-swap, with each step compiling and tests passing. Roll back via `git revert` of the final commit.
- ADR additions are append-only — never edit a published ADR; supersede it.

The fix prompt creates a single git branch (`fix-after-07`) and one commit per logical group, so you can cherry-pick if you want to skip a section.

---

## Open questions for the operator

The fix prompt will pause and ask you to confirm these before acting. Decide ahead of time:

1. **Phase numbering / filename renaming.** Audit recommends renaming for natural sort order. Default plan: skip the renumbering, add navigation headers instead. Confirm or override.
2. **`test-spire` namespace.** Empty for 36+ hours. Delete it, or keep as a regression-test fixture and document it?
3. **Kyverno `verify-image-signatures` mode.** Currently Audit (per ADR-0004). Stay Audit until a dedicated supply-chain phase, or flip to Enforce now? Default plan: stay Audit.
4. **Phase 6b-1 design questions** (ADR-0012 lines 76–83). The four open design questions are: audience-set scope, audience discovery, refresh-token flow on audience change, audit-log actor reconstruction. The fix prompt does not answer these — they need a real design conversation. The prompt only flags this as blocking Phase 6b-1 and Phase 9.
5. **Wazuh.** If Wazuh is deferred indefinitely (not just to Phase 7 Session 2), the namespace should be deleted to reduce surface area. Confirm intent.

---

## Companion: Phase navigation

Cross-phase dependencies and navigation pointers are baked **into the existing project documents** — no separate navigation document. After this fix package runs, every `phase-NN-*.md` will have a header like:

```markdown
> **Navigation:** [⬅ Phase N-1](./phase-N-1.md) · [➡ Phase N+1](./phase-N+1.md) · [PLAN.md](../../PLAN.md)
> **Depends on (must be ✅):** Phase X, Phase Y
> **Blocks:** Phase A, Phase B
```

PLAN.md gets a dependency graph in its header, sourced from `00-audit-findings.md`'s "Dependency Graph (Corrected Execution Order)" section.
