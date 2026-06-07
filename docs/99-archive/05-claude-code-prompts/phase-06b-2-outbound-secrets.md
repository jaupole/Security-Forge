> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 6b-2 — Outbound Secrets Pattern + Guardrails

> **Navigation:** ⬅ [Previous: Phase 6 — Istio + BFF](./phase-06-istio-bff.md) (independent of 6b-0/6b-1) · [Next: Phase 7b — Post-6b-2 Monitoring](./phase-07b-post-6b2-monitoring.md) ➡ (after Phase 7 ✅) · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 6
> **Blocks:** Phase 7b (post-6b-2 monitoring wire-up) · Phase 10 (apps need outbound secrets) · Phase 11
>
> **Status (mirrors PLAN.md, last updated 2026-05-02):** ✅ **Complete — all 7 commits landed.** Quick recap: ADR-0013 ✅ (`aa10402`) → `apps/lib/secrets/` outbound ✅ (`f82700a`, 88.7% cov) → `apps/lib/errreport/` scrubber ✅ (`9803725`, 89.7% cov) → `templates/app-repo/` + Trivy flip ✅ (`af152ea`) → Kyverno + collector + CronJob ✅ (`41e27d1`) → BFF consumer wiring + AuthZEN ADR-0015 cross-ref ✅ (`f549775`) → closeout (8 verify scripts + 6 runbooks + CLAUDE.md no-`.env` rule + Phase 10.{N}.5 update). Operator-time prerequisites + known follow-ups recorded in [PLAN.md § Phase 6b-2 detail block](../../PLAN.md#phase-6b-2--outbound-secrets-pattern--guardrails-2-days).
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2 days

**Prerequisites:**
- Phase 5 ✅ (OpenBao deployed; SPIFFE-JWT auth role for `app` ns SAs configured)
- Phase 6 ✅ (Istio Ambient + helloworld-bff deployed; SPIRE-managed identities working in `app` ns)
- Phase 7 ✅ (Loki/Tempo/Prometheus live so guardrail-bypass events have somewhere to land)
- Phase 6b-1 ✅ — **NOT** required; can run before 6b-1. The two halves are independent. If 6b-1 hasn't run, the `apps/lib/` parent module needs to be created here (mirror Section 1 of 6b-1).

---

## Origin

This file was split out from `phase-06b-api-pattern.md` on 2026-05-01 (Session 4 PLAN.md prompt-rewrite work) when the joint 6b-1/6b-2 doc was retargeted to be 6b-1-only. The 6b-2 content below was never stale — it's about outbound secrets and prevention guardrails, independent of the RFC 8693 token-exchange NO-GO decision (ADR-0012). This file preserves that content as a runnable phase prompt.

---

## Goal

Two deliverables, tightly coupled because the second guards the first:

1. **`apps/lib/secrets/` library** — the `.env`-file replacement. Third-party API credentials (Stripe, OpenAI, SendGrid, SAM.gov, GitHub, etc.) live in OpenBao at `secret/data/apps/<app>/<integration>` and are fetched via SPIFFE-JWT auth at runtime. No keys on disk, in env vars, in images, in source control — ever.

2. **Prevention guardrails** that make `.env` literally hard to use: `.gitignore` + pre-commit hooks + CI checks + Kyverno admission policies + Trivy build-time secret scanning + an error-reporter scrubber wired into a no-op sink today (Phase 7 swaps the sink). Defense in depth: any one layer can be bypassed; all five together cannot without active, deliberate, auditable effort.

Without 6b-2, every app reaches for `.env` on Day 1 of Phase 9/10 and the library is bypassed before it's ever tried.

---

## What you (the operator) need to do first

1. Confirm `apps/lib/` exists with a `go.mod`. If 6b-1 ran first, it does. If not, follow Section 1 of [phase-06b-api-pattern.md](./phase-06b-api-pattern.md#section-1) to create it.
2. Confirm Phase 5's OpenBao JWT auth role for `app` namespace SAs is in place: `bao read auth/jwt/role/<app>` should succeed for the test workload from Phase 5.10.
3. Skim [ADR-0012](../02-decisions/0012-token-exchange-feasibility.md) for context on why secret-side and auth-side are split into 6b-1 / 6b-2.
4. Skim [ADR-0015 — Secret distribution pattern](../02-decisions/0015-secret-distribution-pattern.md) — the VSO/direct-API split that informs `apps/lib/secrets/`'s architecture.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 6b-2 of the SecForge Local Edition platform build.

Read in order before doing anything:
  1. CLAUDE.md
  2. PLAN.md (Phase 6b-2 detail block + table row)
  3. docs/02-decisions/0013-outbound-secrets-no-env.md (the policy this phase enforces)
  4. docs/02-decisions/0015-secret-distribution-pattern.md (VSO vs direct-API)
  5. docs/05-claude-code-prompts/phase-06b-2-outbound-secrets.md (this doc)

Goal: ship apps/lib/secrets/ + the five-layer guardrail stack so that no
SecForge app can accidentally use .env files, env-var-as-secret patterns,
or unencrypted-at-rest K8s Secrets for outbound credentials.

═══════════════════════════════════════════════════════════════════════════
Section 1 — Implement apps/lib/secrets/
═══════════════════════════════════════════════════════════════════════════

Create the Go module at apps/lib/secrets/ (~150-200 LoC total).

Files:
  - secrets.go     — public Client type and New(Config) constructor
  - auth.go        — SPIFFE-JWT-SVID → OpenBao login (reuses spiffe-helper
                     socket OR go-spiffe — pick one and document)
  - kv.go          — Get(ctx, path) (map[string]string, error) for KV-v2
                     reads at secret/data/apps/<app>/<integration>
  - cache.go       — in-memory cache, configurable TTL (default 5 min);
                     cache miss triggers fresh fetch + auth refresh if needed
  - dynamic.go     — GetDynamic(ctx, role) (DBCredential, error) for the
                     database engine path (Phase 5.9 pattern); returns
                     lease ID + renew helper
  - hardened.go    — Hardened mode wrapper + Secret type (see "Hardened
                     mode" below)
  - secrets_test.go — table-driven tests with a fake OpenBao HTTP server

Public API:

  sec := secrets.New(secrets.Config{
      OpenBaoAddr: "https://bao.openbao.svc:8200",
      AppName:     "proposal-forge",        // → namespace under secret/data/apps/
      SVIDSource:  secrets.SPIFFEHelperSocket("/spiffe-workload-api/spire-agent.sock"),
      Audience:    "openbao",
      CacheTTL:    5 * time.Minute,
      Hardened:    true,                     // default for new apps
  })

  // static third-party API key
  openaiKey, err := sec.GetField(ctx, "openai", "api_key")

  // dynamic Postgres credential (Phase 5.9 pattern)
  cred, err := sec.GetDynamic(ctx, "proposal-forge-readwrite")
  defer cred.Revoke(ctx)
  db, err := sql.Open("postgres", cred.DSN())

Constraints (these are how the library prevents the .env-leak failure mode):
  - Library NEVER writes a secret to disk, log, error message, or panic
    message — even on failure. Get errors include the path but never the
    value.
  - TTL refreshes happen in the background; calls during refresh return
    the cached value.
  - Close() zeroes in-memory secrets (best-effort — Go's GC makes this
    imperfect, but document the intent).
  - No fallback to env vars under any circumstance — a missing secret is
    a fail-fast error.
  - Path scheme is Vault Secrets Operator-compatible: paths follow VSO's
    expected layout (secret/data/apps/<app>/<integration>); specifically
    avoid path patterns VSO can't represent via VaultStaticSecret /
    VaultDynamicSecret CRs. Document the chosen scheme in ADR-0013 with
    a worked VaultStaticSecret example.

Hardened mode (the library's secret-hygiene posture):

The library exposes a Hardened bool field in Config. When true:
  - Get returns an error if the value would otherwise be returned as a
    string. Callers must use Use(func(b []byte)) or a helper
    (HTTPHeader, BasicAuth, DSN).
  - Secret is a mandatory wrapper, not optional.
  - Internal logging redacts via the redaction-aware logger; non-redaction-
    aware logging APIs are not exposed.

Default for new apps: Hardened: true. Document the rollout plan in ADR-0013:

  > Hardened-mode rollout plan: New apps default to Hardened. Existing apps
  > (none today; will accumulate as Phase 9/10 land) remain non-Hardened
  > until explicitly migrated. Migration target: pre-AWS-migration (latest
  > acceptable). Each migration is a per-app PR exercising every Hardened-
  > incompatible call site, reviewed for memory hygiene patterns. Once all
  > in-cluster apps are Hardened, the library default flips to Hardened-
  > everywhere and the non-Hardened code path is removed.

OpenBao templated policy (commit to infrastructure/openbao/policies/app-template.hcl):

  path "secret/data/apps/{{identity.entity.aliases.<jwt-mount-accessor>.metadata.app}}/*" {
    capabilities = ["read"]
  }
  path "database/creds/{{identity.entity.aliases.<jwt-mount-accessor>.metadata.app}}-*" {
    capabilities = ["read"]
  }

So an app with SPIFFE ID spiffe://secforge.local/ns/app/sa/proposal-forge
can only read secret/data/apps/proposal-forge/* and database roles prefixed
proposal-forge-. Cross-app reads are denied at the OpenBao policy layer.

═══════════════════════════════════════════════════════════════════════════
Section 2 — Repo-template guardrails (templates/app-repo/)
═══════════════════════════════════════════════════════════════════════════

Create templates/app-repo/ in the platform repo with files every new app
inherits via cp -r:

  - .gitignore — bans .env, .env.*, *.pem, *.key, *.p12, *.crt, id_rsa*,
    with !.env.example as the only exception.
  - .env.example — placeholder showing the *shape* of expected non-secret
    config only (LOG_LEVEL=info, PORT=8080); never any secret-shaped key
    name. Documents that real secrets come from apps/lib/secrets/.
  - .pre-commit-config.yaml with three hooks:
      - gitleaks — scans staged content against the default ruleset plus
        custom rules for any vendor-specific patterns we care about.
      - block-env-files — local hook that fails commit if any .env* file
        is staged (except .env.example).
      - block-secret-shaped-vars — local hook that greps staged Go files
        for os.Getenv("...KEY..."), os.Getenv("...SECRET..."), etc., and
        fails the commit, pointing the author at apps/lib/secrets/.
  - .gitleaks.toml — custom rule additions if needed.
  - README-secrets.md — short "if you're about to add a secret, do this
    instead" doc that ships in every app repo.
  - .template-version — file containing the templates/ semver. Phase 7's
    drift-detection cron compares each app's .template-version against
    the platform repo's current version and surfaces apps drifting behind.

Document the cp-and-init pattern in docs/03-runbooks/new-app-bootstrap.md.

═══════════════════════════════════════════════════════════════════════════
Section 3 — CI guardrails
═══════════════════════════════════════════════════════════════════════════

Pre-commit hooks can be bypassed with git commit --no-verify. CI cannot.
Mirror every pre-commit check as a CI check that blocks merge.

In templates/app-repo/.github/workflows/secrets-check.yml (or equivalent
for the chosen CI):
  - gitleaks-action scanning the entire history of the PR's diff.
  - Custom step running the same block-env-files + block-secret-shaped-vars
    checks as pre-commit.
  - Step that checks the Dockerfile for COPY .env*, COPY . . without a
    corresponding .dockerignore entry, ENV <SECRET-LOOKING>=... patterns.
  - Step that fails the build if any artifact upload step would include
    .env*.

Document in docs/03-runbooks/ci-secrets-check.md. Make this required for
merge on every app repo via branch protection rules — note in the runbook
how to set this up.

═══════════════════════════════════════════════════════════════════════════
Section 4 — Image-build guardrails
═══════════════════════════════════════════════════════════════════════════

Build-time:
  - Verify Trivy is configured to FAIL the build on secret findings, not
    warn. If Phase 1's Trivy setup is warn-only, change it. Update
    infrastructure/cosign/ (or wherever the build pipeline lives) to fail
    on Trivy's --severity HIGH,CRITICAL plus --scanners secret.
  - Multi-stage Dockerfile lint: templates/app-repo/Dockerfile.example
    shows the canonical pattern (build stage with deps, final stage with
    only the binary). Add hadolint to pre-commit + CI with rules DL3045
    (no COPY without explicit destination), DL3025 (use JSON array form),
    and a custom rule rejecting COPY . . without an adjacent .dockerignore.
  - templates/app-repo/.dockerignore bans the same patterns as .gitignore
    plus Dockerfile, *.md, tests/, node_modules/, .git/.

Runtime — Kyverno cluster policy infrastructure/kyverno/policies/no-secret-shaped-env.yaml:

  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: no-secret-shaped-env-vars
    annotations:
      policies.kyverno.io/severity: high
  spec:
    validationFailureAction: Enforce
    background: true
    rules:
      - name: block-secret-shaped-env-names
        match:
          any:
            - resources:
                kinds: [Pod]
                namespaces: [app]
        validate:
          message: >
            Secret-shaped environment variables are banned. Names matching
            *KEY*, *SECRET*, *TOKEN*, *PASSWORD*, *CREDENTIAL* must be
            fetched via apps/lib/secrets/ from OpenBao, not set as env vars.
            See docs/03-runbooks/secrets-library.md.
          pattern:
            spec:
              =(initContainers):
                - =(env):
                    - name: "X(*KEY*|*SECRET*|*TOKEN*|*PASSWORD*|*CREDENTIAL*)"
              containers:
                - =(env):
                    - name: "X(*KEY*|*SECRET*|*TOKEN*|*PASSWORD*|*CREDENTIAL*)"

Self-expiring escape hatch (the only acceptable way to deploy a secret-
shaped env var, transitional only):

  metadata:
    annotations:
      secforge.local/legacy-secret-env: "JIRA-1234"           # required
      secforge.local/legacy-secret-env-expires: "2026-07-30"  # ISO date, max 90d out

A second Kyverno ClusterPolicy legacy-secret-env-expiry enforces:
  - If legacy-secret-env annotation is present, expires must also be present
  - expires must parse as ISO date
  - expires must be ≤ 90 days from admission time
  - expires must be in the future at admission time

A daily CronJob scans existing pods carrying the annotation and emits
secrets.guardrail.bypass events with severity=high for any expiring within
14 days.

═══════════════════════════════════════════════════════════════════════════
Section 5 — Runtime hygiene patterns in apps/lib/secrets/
═══════════════════════════════════════════════════════════════════════════

Update apps/lib/secrets/ (Section 1's library) with these guarantees
enforced in code, documented in the runbook:

  - The struct holding a fetched secret implements String() string returning
    "<redacted>", and MarshalJSON() returning "\"<redacted>\"". Anyone who
    logs the struct gets the redacted form by default.
  - A Secret type wraps []byte rather than string for the actual value, with
    a Use(func(b []byte)) accessor pattern so callers don't keep references
    hanging in their own variables. After Use returns, the library zeroes
    the slice (best-effort, documented as imperfect due to GC).
  - Optional secrets.Hardened mode that disables Get returning the raw value
    at all; callers must use Use or one of the helpers (HTTPHeader,
    BasicAuth, DSN). Default is Hardened for new apps.
  - Library refuses to log via slog / log by design — any internal logging
    happens through a redaction-aware logger that masks any value the
    library returned.

Add a "common mistakes" section to docs/03-runbooks/secrets-library.md
covering: putting the secret back into an env var "for convenience,"
interpolating it into a fmt.Errorf, capturing it in a closure that outlives
the request, sending it to Sentry/error reporters via panic context.

═══════════════════════════════════════════════════════════════════════════
Section 6 — Error-reporter scrubbing (wired in, not just committed)
═══════════════════════════════════════════════════════════════════════════

Phase 6b-2 ships the scrubber WIRED INTO A NO-OP SINK, not just committed
as inert middleware. The no-op sink is a Reporter interface implementation
that runs all scrubbing rules and writes the cleaned event to STDOUT (or
/dev/null in tests). This closes the gap where "scrubber exists but isn't
running" — every error path that *would* go to Sentry runs through the
scrubber today, even though there's no Sentry yet.

When Phase 7 wires up the real reporter (Sentry/Rollbar/OTel), the only
change is swapping the sink implementation.

  // apps/lib/errreport/reporter.go
  type Reporter interface {
      Capture(ctx context.Context, err error, tags map[string]string)
  }

  type Scrubber interface {
      Scrub(payload []byte) []byte  // applies all rules, returns cleaned bytes
  }

  type ScrubbingReporter struct {
      Scrubber Scrubber
      Sink     Reporter  // no-op in 6b-2, real reporter in Phase 7
  }

The scrubber rules cover:
  - Environment variable values for keys matching the same secret-shaped
    pattern as the Kyverno policy.
  - Any string matching common secret prefixes: sk_live_, sk_test_, xoxb-,
    ghp_, gho_, bao., eyJ (JWT-shaped).
  - The library's Secret type via String() — error reporters often
    serialize via reflection; add a default scrubber rule.

Apps wire errreport.New(scrubber, errreport.NoOpSink{}) in 6b-2. Phase 7
changes one line per app to use errreport.SentrySink{...} (or whichever
reporter is chosen).

Add a unit test that the scrubber receives every Capture call before the
sink does.

═══════════════════════════════════════════════════════════════════════════
Section 7 — Verification (executable, not a manual checklist)
═══════════════════════════════════════════════════════════════════════════

Manual checklists rot. Package the verification as an executable test
suite under infrastructure/secrets-guardrails/verify/:

  01-precommit-blocks-env.sh         tries to git add .env, asserts blocked
  02-ci-blocks-no-verify.sh          PRs a --no-verify commit, asserts CI fails
  03-kyverno-denies-secret-env.sh    kubectl apply Pod with STRIPE_API_KEY env, asserts denied
  04-trivy-fails-on-env-in-image.sh  builds image with .env in context, asserts Trivy fails
  05-precommit-blocks-secret-getenv.sh  tries to commit os.Getenv("OPENAI_KEY"), asserts blocked
  06-secret-redacts-in-printf.sh     runs Go binary that fmt.Printfs a Secret, asserts == "<redacted>"
  07-secret-redacts-in-panic.sh      runs binary that panics with a Secret in scope, asserts captured context redacted
  08-annotated-bypass-emits-event.sh admits Pod with valid expiring escape-hatch annotation, asserts admission AND one severity=high event
  run-all.sh                          single entry point; exits 0 only if all pass

Each script:
  - Sets up a deterministic precondition (clean repo state, fresh test pod).
  - Performs the deliberate violation.
  - Asserts the expected outcome (block + event), with the expected event
    structure parsed from the collector's STDOUT or webhook.
  - Cleans up (removes test pods, reverts staged files).
  - Exits 0 on success, non-zero with a clear message on failure.

Phase 7 schedules run-all.sh as a weekly cron; failures emit
severity=critical events.

Document the runbook docs/03-runbooks/secrets-guardrails-verification.md
with the exact commands, expected outputs, and instructions for adding a
9th case when a new guardrail layer is added.

═══════════════════════════════════════════════════════════════════════════
Section 8 — Log every bypass for monitoring
═══════════════════════════════════════════════════════════════════════════

Defense-in-depth only works if bypasses are visible. Every layer above can
be circumvented; the goal of this section is to make sure each circumvention
emits a structured event that lands somewhere reviewable.

Event shape (consistent across all sources):

  {
    "ts": "2026-04-30T14:22:01Z",
    "event": "secrets.guardrail.bypass",
    "layer": "kyverno|gitleaks|trivy|precommit|ci|kubernetes-secret|library-redaction",
    "severity": "warn|high|critical",
    "actor": "<git author email | k8s user | service account>",
    "resource": "<repo+path | pod name | image+layer | etc>",
    "rule": "<rule id that fired or was bypassed>",
    "outcome": "blocked|annotated-bypass|warn-only|leaked",
    "annotation_ref": "<ticket id if escape-hatch annotation used>",
    "request_id": "<correlation id when available>"
  }

Per-layer emission (full per-source detail in the runbook):
  1. Pre-commit: emit nothing locally (developer machines, no log shipping).
     Acceptable because CI is the auditable layer for the same checks.
  2. CI guardrails: every CI failure of these checks emits the event JSON
     to STDOUT in the job log AND posts to a webhook
     (SECURITY_EVENTS_WEBHOOK_URL) with the structured event.
  3. Trivy: configure trivy.yaml to emit JSON results. CI step parses
     Trivy JSON and emits one event per detected secret.
  4. Kyverno: validationFailureAction: Enforce policies emit
     PolicyViolation events natively. Configure kyverno-events-exporter
     (or built-in policy-reporter) to translate PolicyViolation into the
     secrets.guardrail.bypass shape. Specifically log:
       - Every block (outcome: blocked)
       - Every admission that used the legacy-secret-env annotation
         (outcome: annotated-bypass) — most important to monitor because
         these are permitted bypasses that can pile up.
  5. K8s Secret creation in `app` ns: a second Kyverno policy in Audit
     mode emits an event for every Secret created in `app` ns post-cutover.
     Catches drift back to the K8s-Secret-as-secret pattern.
  6. apps/lib/secrets/ library:
       - Hardened mode disabled by config at startup → severity high
       - Secret.String() called → severity warn (logging the wrapper)
       - Scrubber rule fires in error-reporter middleware → severity high
  7. Image build pipeline: docker buildx step that diffs .dockerignore
     against the build context. If .dockerignore was modified to allow
     .env patterns since the last build → severity critical event.

apps/security-events-collector/ HTTP service receives webhook events
from CI runners and Kyverno. Authentication:
  - In-cluster callers (Kyverno, library hygiene checks, image-build
    pipeline running in-cluster) authenticate via SPIFFE-SVID. The collector
    reuses apps/lib/api-auth/ middleware (from Phase 6b-1) to verify the
    SVID and resolve a verified caller identity.
  - Out-of-cluster callers (CI runners outside Docker Desktop) authenticate
    via a short-lived JWT issued by a dedicated Keycloak client
    security-events-ci.
  - The collector tags every accepted event with the VERIFIED actor in
    the actor field, OVERRIDING whatever the event payload claims. Closes
    the "trust the payload" weakness.
  - Unauthenticated requests are rejected with 401 and logged as their own
    secrets.guardrail.bypass event with severity=high.

Every emission includes request_id when one is in scope.

Verification: extend the eight cases from Section 7 — each deliberate
failed attempt must ALSO produce exactly one corresponding
secrets.guardrail.bypass event in the expected log destination. Plus a
ninth case: deploy a Pod with the escape-hatch annotation; confirm
admission succeeds AND a outcome: annotated-bypass event fires.

Privacy guardrail on the events themselves: the events MUST NOT contain
the leaked secret value. Add a unit test that fuzzes the emission code
with secret-shaped inputs and asserts no recognizable secret pattern
(sk_live_, eyJ, xoxb-) appears in any emitted event.

Document in docs/03-runbooks/secrets-guardrails-monitoring.md.

═══════════════════════════════════════════════════════════════════════════
Section 9 — Documentation
═══════════════════════════════════════════════════════════════════════════

Update or write:
  - docs/02-decisions/0013-outbound-secrets-no-env.md (refresh / verify
    matches what's been implemented; add the worked VaultStaticSecret
    example per the VSO-compatibility constraint)
  - docs/03-runbooks/secrets-library.md — how to use apps/lib/secrets/,
    common mistakes, how to add a new third-party integration, how
    rotation works
  - docs/03-runbooks/migrate-env-to-openbao.md — step-by-step for
    converting existing .env-driven projects: inventory secrets → write
    to OpenBao → swap library calls → delete .env → audit git history
    for committed secrets → rotate any that were ever in git
  - docs/03-runbooks/new-app-bootstrap.md — cp-and-init from
    templates/app-repo/
  - docs/03-runbooks/secrets-guardrails-verification.md — Section 7's
    test suite
  - docs/03-runbooks/secrets-guardrails-monitoring.md — Section 8's event
    schema, per-layer emission contract, Phase 7 ingestion wire-up
  - docs/03-runbooks/ci-secrets-check.md — Section 3's CI checks
  - CLAUDE.md — add to "Things that should NEVER happen": "Storing third-
    party API keys, integration credentials, or any secret in .env files,
    env vars, ConfigMaps, K8s Secrets, or source control. All such secrets
    live in OpenBao and are fetched via apps/lib/secrets/."
  - docs/05-claude-code-prompts/phase-09-hello-world.md — change Phase 9
    backend prompt to "use apps/lib/secrets/ for any outbound creds"
  - docs/05-claude-code-prompts/phase-10-develop-apps.md — add "all
    backend APIs MUST use apps/lib/secrets/ outbound. No .env files
    anywhere in app code."
  - PLAN.md — mark Phase 6b-2 ✅ with Session-N summary; bump Last updated
```

---

## Constraints

- Library 150-200 LoC; no env-var fallbacks anywhere.
- Library NEVER writes a secret to disk, log, error message, or panic message.
- All four Kyverno escape-hatch annotation rules tested: missing-expiry denied, past-expiry denied, far-future-expiry denied, valid annotation admitted with event emission.
- Fuzz test confirms no secret pattern (`sk_live_`, `eyJ`, `xoxb-`, etc.) ever appears in any emitted event regardless of input.
- `apps/security-events-collector/` rejects unsigned/unauthenticated webhook calls.

## Success criteria

- [ ] `apps/lib/secrets/` builds; all unit tests pass
- [ ] OpenBao templated policy lets each app read only `secret/data/apps/<its-name>/*`; cross-app read denied (verify with a test workload)
- [ ] CLAUDE.md updated with the no-`.env` rule
- [ ] `templates/app-repo/` committed: `.gitignore`, `.env.example`, `.pre-commit-config.yaml`, `.dockerignore`, `Dockerfile.example`, `README-secrets.md`, CI workflow snippet, `.template-version`
- [ ] Kyverno `no-secret-shaped-env-vars` ClusterPolicy admitted in Enforce mode; deliberate test Pod with `STRIPE_API_KEY` env var is denied
- [ ] Trivy fails builds (not warns) on secret findings; verified by deliberate failure case
- [ ] Pre-commit + CI both block: a `.env` commit, a `.env` commit with `--no-verify`, an `os.Getenv("OPENAI_KEY")` line of Go
- [ ] `apps/lib/secrets/` `Secret` type redacts via `String()`/`MarshalJSON()`; verified by intentional `fmt.Printf("%v", sec)`
- [ ] **Error-reporter scrubber wired into a no-op `Reporter` sink** (not just committed) so every error path runs through the scrubber today; Phase 7 only swaps the sink, scrubber unchanged
- [ ] OpenBao path scheme is **VSO-compatible**; ADR-0013 includes a worked `VaultStaticSecret` example as proof
- [ ] `apps/lib/secrets/` `Hardened: true` is the default for new apps; ADR-0013 documents the rollout plan
- [ ] All 8 executable verification scripts under `infrastructure/secrets-guardrails/verify/` pass via `run-all.sh`
- [ ] Each verification case emits exactly one `secrets.guardrail.bypass` event in the documented JSON shape
- [ ] `apps/security-events-collector/` HTTP webhook receiver deployed; **authenticates inbound CI/Kyverno calls via SPIFFE-SVID or short-lived JWT**; rejects unsigned requests with 401 and emits a `severity=high` event
- [ ] Collector overrides payload-claimed `actor` with the verified caller identity (test: send a forged actor in payload, assert it's overridden)
- [ ] Self-expiring escape hatch verified: `legacy-secret-env` annotation without `expires` is denied; `expires` > 90d is denied; past `expires` is denied; valid annotation admits + emits event; daily CronJob emits 14-day-pre-expiry warnings
- [ ] Fuzz test confirms no secret pattern ever appears in an emitted event regardless of input
- [ ] `docs/03-runbooks/secrets-guardrails-monitoring.md` published with event schema + Phase 7 wire-up instructions
- [ ] Phase 9 and Phase 10 prompts updated to mandate the library

## Troubleshooting

**"OpenBao read returns 403 for an app's own path"**
Templated policy substitution failed. Confirm the JWT mount metadata includes `app=<name>` (set in the OpenBao role bound to the SPIFFE ID — `bao write auth/jwt/role/<app> bound_audiences=openbao user_claim=sub bound_subject=spiffe://secforge.local/ns/app/sa/<app> token_metadata=app=<app>`). Without `token_metadata`, the templated path resolves to empty.

**"Secret value leaked in error message or stack trace"**
The library should never include values in errors. If you see one, it's a bug in `apps/lib/secrets/` — fix the library, then audit Loki for past leaks and rotate any affected credentials. Treat as a security incident, not a bug fix.

**"Kyverno blocks a legitimate Pod"**
The `no-secret-shaped-env-vars` policy is intentionally pattern-aggressive. If a legitimate non-secret env var like `JWT_ISSUER_URL` matches `*JWT*`... wait, JWT isn't on the banlist. The banlist is `*KEY*`, `*SECRET*`, `*TOKEN*`, `*PASSWORD*`, `*CREDENTIAL*`. If your variable name actually contains one of those substrings and the value is *not* a secret, rename the variable. The policy is correct; the variable name is the bug.

## What's next

[Phase 7b — Post-6b-2 Monitoring Wire-up](./phase-07b-post-6b2-monitoring.md) (depends on this phase ✅).
