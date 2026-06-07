# Outbound-secrets guardrail monitoring

> **Source of truth:** [Phase 6b-2 prompt § Section 8](../99-archive/05-claude-code-prompts/phase-06b-2-outbound-secrets.md#section-8) +
> [`apps/security-events-collector/event.go`](../../apps/security-events-collector/event.go)
> **ADR:** [ADR-0013 § 8](../02-decisions/0013-outbound-secrets-no-env.md)

Defense-in-depth only works if bypasses are visible. This runbook
covers the canonical `secrets.guardrail.bypass` event schema, the
per-layer emission table, and the Phase 7b wire-up plan that lights
this up in Grafana / Alertmanager.

## Event schema

Every guardrail bypass — pre-commit, CI, Trivy, Kyverno, K8s Secret
creation, library redaction failure, image-build hygiene — emits a
single shape:

```json
{
  "ts":             "2026-05-02T14:22:01Z",
  "event":          "secrets.guardrail.bypass",
  "layer":          "kyverno|gitleaks|trivy|precommit|ci|kubernetes-secret|library-redaction",
  "severity":       "warn|high|critical",
  "actor":          "<verified caller — overridden server-side>",
  "resource":       "<repo+path | pod name | image+layer | etc>",
  "rule":           "<rule id that fired or was bypassed>",
  "outcome":        "blocked|annotated-bypass|warn-only|leaked",
  "annotation_ref": "<ticket id if escape-hatch annotation used>",
  "request_id":     "<correlation id when available>"
}
```

The `event` field is a hard-coded discriminator; payloads with any
other value are rejected at `Event.Validate` time. `layer`, `severity`,
and `outcome` are closed enums. Any unknown value fails validation.

## Per-layer emission table

| Layer | Source | Emission point | Notes |
|---|---|---|---|
| 1 — Pre-commit | Developer machine | None (advisory) | CI mirrors the same checks for the auditable record |
| 2 — CI | GitHub Actions / equivalent | Job log `::error::` line + webhook POST to `security-events-collector` (when `SECURITY_EVENTS_WEBHOOK_URL` is configured) | Phase 7b wires the webhook URL into the workflow |
| 3 — Build-time | Trivy + hadolint | `build.sh` parses Trivy JSON, emits one event per detected secret | `apps/security-events-collector/build.sh` is the reference; commit 3 flipped Trivy to `--scanners vuln,secret --severity HIGH,CRITICAL` |
| 4 — Admission | Kyverno | `policy-reporter` (or built-in `PolicyViolation` event exporter) translates into the canonical schema. Includes `annotated-bypass` on legacy-env-annotated admissions | Phase 7b wires policy-reporter; until then PolicyReports are the audit trail |
| 5 — K8s Secret in `app` ns | Kyverno (Audit mode) | One event per Secret created in `app` ns post-cutover | Drift detector — catches operators who fall back to `kubectl create secret` for outbound creds |
| 6 — Library redaction | `apps/lib/secrets/` + `apps/lib/errreport/` | Hardened-mode-disabled at startup (severity high), `Secret.String()` called (severity warn — defensive — only happens via reflection in serializers), Scrubber rule fires (severity high) | All emissions go through `apps/lib/errreport/` `ScrubbingReporter` to the same collector |
| 7 — Image build pipeline | `docker buildx` | `.dockerignore` diff against build context; if `.dockerignore` was edited to PERMIT `.env*` since the previous build, severity=critical | Hooks into Phase 9+ image-build pipeline; today the pre-commit + CI checks cover the same shape |

## Authentication on the collector

All emitters POST to `security-events-collector`'s
`/v1/secrets/guardrail/bypass`. The collector validates the inbound
JWT and **overrides** the payload-claimed `actor` field with the
verified caller identity:

- **In-cluster callers** (Kyverno reporter, library hygiene checks,
  in-cluster image-build pipeline): SPIFFE-SVID via Istio Ambient mTLS;
  resolved to `spiffe://secforge.platform/ns/<ns>/sa/<sa>` form.
- **Out-of-cluster callers** (CI runners outside Docker Desktop):
  short-lived JWT issued by the `security-events-ci` Keycloak client;
  resolved to `kc:<sub>` form.
- **Unauthenticated requests** are rejected 401 AND emit their own
  synthetic `severity=high, actor=unauthenticated, outcome=blocked`
  event so silent rejection cannot mask probing.

This closes the "trust the payload" weakness — a compromised CI runner
cannot launder identity by claiming to be a different actor in the
event payload.

## Sink today (Phase 6b-2)

The collector writes one JSON-line per accepted event to **stdout**.
Phase 7b's Promtail tails the container logs.

## Phase 7b — wire-up (live as of 2026-05-02)

The sketch in the section below is now the live config. Three pieces:

**1. Promtail scrape job `secrets-guardrails`** (committed in
`platform/values/promtail.yaml` §
`extraScrapeConfigs`):

- Discovers Pods labeled `app.kubernetes.io/name=security-events-collector` across all namespaces.
- JSON-parses each line; drops anything that isn't the canonical
  `secrets.guardrail.bypass` event.
- Promotes `severity, layer, rule, outcome, actor` to indexed labels
  (wider than Loki best-practice usually wants, bounded in practice
  by the closed enums + per-workload SPIFFE-ID clustering).
- Emits a Prometheus counter via the `metrics:` pipeline stage. Note
  the **actual metric name is `promtail_custom_secrets_guardrail_bypass_total`** —
  Promtail prefixes user-defined counters with `promtail_custom_`,
  which is easy to miss when writing PrometheusRule expressions
  against it.

**2. Loki per-stream retention** (`platform/values/loki.yaml` §
`limits_config.retention_stream`): 90d for `{job="secrets-guardrails"}`,
14d global. Aspirational until `compactor.retention_enabled: true`
flips — the diagnostic comment in the values file documents why
that's still off (fresh-bucket boot loop on missing
`delete_requests.gz`); flip in a separate change once the bucket
has accumulated at least one delete request and Loki still reaches
`/ready` post-restart.

**3. PrometheusRule group `secforge.secrets-guardrails`** (4 rules in
`platform/manifests/observability/09-platform-alerts.yaml`):

| Alert | Trigger | Severity |
|---|---|---|
| `SecretsGuardrailBypassCritical` | any `severity=critical` event in 5m | critical |
| `SecretsGuardrailBypassHigh` | any `severity=high` event in 5m, 1m delay | high |
| `SecretsGuardrailAnnotatedBypassActiveOver30d` | annotated-bypass label group emitting events for >30d | medium (weekly digest) |
| `SecretsGuardrailBypassRateAnomaly` | current 1h rate >2σ above 7d rolling avg | medium (Slack/email <4h) |

## Phase 7b — secrets-guardrails CronJobs

Two weekly CronJobs (deployed under `platform/manifests/`),
applied via `bash apply.sh`:

- **`weekly-guardrail-verify`** (Sunday 02:00 UTC): mounts the verify
  scripts as a ConfigMap and runs `bash run-all.sh` in offline mode
  (the LIVE-mode probes need the host's `kubectl + docker` which the
  CronJob doesn't have). On non-zero exit, it POSTs a
  `severity=critical, rule=weekly-verify-regression` event to the
  collector. Backstop alert: `kube_job_failed{job_name=~"weekly-guardrail-verify-.*"}`
  fires regardless of whether the event POST is accepted.
- **`weekly-template-drift`** (Sunday 03:00 UTC, after weekly verify):
  scans Pods for `secforge.platform/template-version` annotations
  predating a 30-day staleness window. At commit time (2026-05-02)
  no app stamps that annotation yet — the marker convention lands
  with Phase 9/10. The CronJob runs harmlessly until those markers
  exist; the first drift event will fire when an app pins to a
  template version older than 30 days.

## Operator-backlog #12 caveat (verify-08 phase-2 + weekly CronJobs)

The collector's auth middleware (apps/lib/api-auth/) requires DPoP
unconditionally — see operator-backlog #12. Practical consequence
for the 7b wire-up:

- The `legacy-env-warner` CronJob's wget POSTs to the collector
  cannot speak DPoP, so each emission gets `ErrDPoPMissing` →
  synthesized `{actor:"unauthenticated", outcome:"blocked",
  rule:"collector.auth: apiauth: invalid token"}` rejection event.
- Same applies to `weekly-guardrail-verify` and `weekly-template-drift`
  CronJob emissions.
- Net effect: until #12 lands, the **annotated-bypass and
  expiring-annotation panels** on the Grafana dashboard stay empty
  even though events are flowing — they all land on the **Rejected
  probes** panel (`outcome=blocked, actor=unauthenticated`) instead.
- This is documented inline on the dashboard panel descriptions and
  in the PrometheusRule comment block. It is not a regression in 7b's
  wire-up; it's a cleanly-deferred verification path.

The Promtail metric counter still increments (with `severity=high`,
`outcome=blocked`), so 7b's pipeline IS exercised end-to-end —
just on the rejection-event leg rather than the accepted-event leg.

## Phase 7b sketch — promtail scrape config snippet

## Privacy guardrail on the events themselves

Per ADR-0013, the events MUST NOT contain leaked secret values.
`apps/security-events-collector/redact_test.go`'s
`FuzzEmitNoSigilSurvives` is the property-based test for this
invariant; the unit test verifies seven vendor-prefix sigils never
appear in any sink-emitted line.

If a future event source (e.g., a new Kyverno policy reporter) is
shipping events whose `resource` field contains the leaked value, file
an ADR amendment to widen the scrubber regex and add a fixture to the
fuzz corpus.

## Operational queries

### "Which apps used the escape hatch in the last week?"

```logql
{app="security-events-collector"} | json | outcome="annotated-bypass" | line_format "{{.actor}} {{.annotation_ref}} {{.resource}}"
```

Group by `annotation_ref` to see ticket-level usage; group by `actor`
to see app-level adoption.

### "Are any escape hatches expiring within 7 days?"

The legacy-env-warner CronJob runs daily at 06:00 UTC and emits one
event per Pod expiring within 14 days. The 7-day-narrowing query:

```logql
{app="security-events-collector"} | json
  | rule="legacy-secret-env-expiry-warning-14d"
  | line_format "{{.resource}} expires={{.annotation_ref}}"
```

### "Did any layer emit a critical event in the last hour?"

```logql
{app="security-events-collector"} | json | severity="critical" | __error__=""
```

A non-empty result means a guardrail flagged something Phase 7b's
alerts will page on.

## Related

- [`apps/security-events-collector/`](../../apps/security-events-collector/) — the receiver
- [secrets-guardrails-verification.md](./secrets-guardrails-verification.md) — the verify suite
- [secrets-library.md](./secrets-library.md) — the library that produces Layer 5+6 events
- [ci-secrets-check.md](./ci-secrets-check.md) — Layer 2's CI mirror
- [ADR-0013 § 8](../02-decisions/0013-outbound-secrets-no-env.md) — the policy
