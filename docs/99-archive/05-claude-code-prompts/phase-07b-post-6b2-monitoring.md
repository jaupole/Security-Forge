> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 7b — Post-6b-2 Monitoring Wire-up

> **Navigation:** ⬅ [Previous: Phase 7 — Observability](./phase-07-observability.md) AND [Phase 6b-2 — Outbound Secrets](./phase-06b-2-outbound-secrets.md) · [Next: Phase 8 — Teleport](./phase-08-teleport.md) ➡ (or skip to [Phase 9 — Hello World](./phase-09-hello-world.md) if Teleport is skipped) · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 7 ✅ AND Phase 6b-2 ✅
> **Blocks:** Phase 9 (the secrets guardrail dashboards + alerts must be live before apps that hit the guardrails ship)
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ HOLD until Phase 6b-2 ✅. (Phase 7 ✅ alone is not sufficient; 7b is the wire-up of 6b-2's emitted events into Phase 7's stack.)
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 1-2 days

**Prerequisites:** Phase 7 complete (observability stack live) AND Phase 6b-2 complete (secret-guardrail emission paths exist in cluster).

---

## Goal of this phase

Phase 6b-2 builds the secret-guardrail emission paths — Kyverno policies, pre-commit hooks, CI checks, the runtime scrubber, the `apps/security-events-collector/` webhook receiver, and the eight-case verification script suite. Phase 7 builds the observability stack (Loki + Grafana + Alertmanager + Promtail). Phase 7b wires those two together: every layer of guardrail emission becomes observable, alertable, and durably retained.

This is deliberately a separate phase rather than carrying the wire-up into Phase 7 itself, because:

1. Phase 6b-2 may or may not be complete by the time Phase 7 lands — they're both schedulable independently.
2. The wire-up is concrete and bounded once both upstreams exist; bundling it into Phase 7 would muddle Phase 7's scope and make verification ambiguous.
3. If 6b-2 ships AFTER 7 (entirely possible), this phase exists as the documented integration point rather than a "Phase 7 amendment."

---

## What you (the human) need to do first

1. Confirm Phase 7 is complete and Loki/Grafana/Alertmanager/Promtail are healthy.
2. Confirm Phase 6b-2 is complete: `apps/security-events-collector/` is deployed, the eight-case verification scripts under `infrastructure/secrets-guardrails/verify/run-all.sh` pass, and `secrets.guardrail.bypass` events are being emitted (visible via `kubectl logs` on the collector pod).
3. Verify that the no-op sink in the runtime scrubber from 6b-2 is still wired (it's the swap target for this phase).

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 7b of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, docs/05-claude-code-prompts/phase-06b-api-pattern.md (Phase 6b-2 section), and docs/05-claude-code-prompts/phase-07b-post-6b2-monitoring.md before doing anything.

Your task is to wire Phase 6b-2's secret-guardrail emission paths into Phase 7's observability stack so every guardrail event becomes observable, alertable, and audit-retained.

## Phase 7b.1 — Promtail scrape config

Add a Promtail scrape config that targets `apps/security-events-collector/` STDOUT with the label `job=secrets-guardrails`. The collector emits one structured JSON line per `secrets.guardrail.bypass` event (schema defined in Phase 6b-2 ADR-0013). Promtail should:

- Parse the JSON
- Promote the following fields to indexed labels: `severity`, `layer`, `rule`, `outcome`, `actor`
- Leave the rest in the log line for full-text search
- Handle malformed lines gracefully (log to a `parse_errors` job; don't drop the source pod)

Verify by triggering a known-good guardrail bypass (e.g., a test pod with a `*KEY*` env var that's annotated with the self-expiring escape hatch) and confirming the event appears in Loki within 30 seconds, fully labeled.

## Phase 7b.2 — Loki retention policy

Configure a 90-day retention policy for `{job="secrets-guardrails"}` streams. This is longer than the default 14-day app-log retention because secret-guardrail events are part of the audit trail.

Implementation: Loki's per-stream retention via `limits_config.retention_stream` (or equivalent in your Loki version). Retention is enforced by the compactor; verify the compactor is running and configured correctly.

## Phase 7b.3 — Grafana dashboard "Secrets Guardrails"

Commit a new dashboard JSON to `infrastructure/grafana/dashboards/secrets-guardrails.json`. Required panels:

1. **Bypass rate by layer/actor/rule** — time-series, last 7 days, broken down by `layer` (pre-commit / CI / Kyverno / runtime), `actor`, and `rule`
2. **Annotated-bypass aging panel** — table of currently-active bypass annotations with their `legacy-secret-env-expires` date, days remaining, and the originating ticket ID
3. **Critical-event timeline** — annotated time-series of `severity=critical` events with the rule name as the annotation
4. **Expiring-annotation panel** — list of pods whose `legacy-secret-env-expires` is within the next 14 days; sorted by closest expiry first

Provision via ConfigMap (same pattern as the Phase 7 dashboards). Tag the dashboard `secrets`, `guardrails`, `audit`.

## Phase 7b.4 — Alertmanager rules

Add the following rules to Alertmanager (committed under `infrastructure/alertmanager/rules/secrets-guardrails.yaml`):

| Trigger | Severity | Route |
|---|---|---|
| `secrets.guardrail.bypass{severity="critical"}` | critical | page immediately |
| `secrets.guardrail.bypass{severity="high"}` | high | Slack/email within 1h |
| `outcome="annotated-bypass"` aged > 30 days without ticket resolution | medium | weekly digest |
| 7-day rolling-baseline anomaly on bypass rate (>2σ) | medium | Slack/email within 4h |

Locally, "page immediately" can route to a webhook stub or just to logs, but the rule structure must match what cloud Alertmanager will use.

## Phase 7b.5 — Scrubber sink swap

Phase 6b-2 wired the runtime error-reporter scrubber into a no-op sink. Swap that for the real OpenTelemetry exporter (collector endpoint already deployed in Phase 7.5).

The scrubber itself does not change — only the sink target. Verify by emitting a known-non-secret error from one of the BFF pods and confirming it appears in Tempo (or wherever non-secret errors land in the OTel pipeline). Then emit a near-leak (an error message that contains a fragment matching the secret-shape regex) and confirm the scrubber redacts before the OTel exporter sees it.

## Phase 7b.6 — Weekly guardrail-verification cron

Schedule a CronJob in the cluster (namespace: `secrets-guardrails-cron`, or co-locate with the collector if that namespace exists) that runs `infrastructure/secrets-guardrails/verify/run-all.sh` every Sunday at 02:00 local. The CronJob:

- Mounts the verify scripts as a ConfigMap
- Has minimal RBAC (read-only against the resources it inspects)
- On failure, emits a `secrets.guardrail.bypass` event with `severity=critical` and `rule=weekly-verify-regression` so it routes through Alertmanager normally

This catches guardrail regressions same week — same idea as security-test-in-CI but for the deployed cluster's guardrail posture.

## Phase 7b.7 — Weekly template-drift cron

Schedule a CronJob that scans every app repo's `.template-version` against the latest `templates/app-repo/` and opens a PR for outdated apps with the diff. Locally, "opens a PR" can be relaxed to "writes a report to MinIO and emits an event"; cloud edition wires it to GitHub via a deploy key.

This prevents bootstrapped guardrails from rotting silently as Trivy/Kyverno/Go versions move forward — a concrete failure mode without it.

## Phase 7b.8 — Verification

End-to-end smoke test:

1. Trigger a deliberate guardrail violation (e.g., admit a pod with `MY_SECRET_KEY` env var without the escape-hatch annotation)
2. Verify Kyverno blocks admission AND emits the `secrets.guardrail.bypass` event
3. Verify the event lands in Loki with full labels within 30 seconds
4. Verify the event appears on the Grafana "Secrets Guardrails" dashboard's bypass-rate panel within one refresh cycle
5. Verify Alertmanager routes a `severity=high` notification (or higher, depending on rule classification)

Then trigger a `severity=critical` event (e.g., violate `infrastructure/secrets-guardrails/verify/run-all.sh` by removing a known-required guardrail and re-running) and verify it pages immediately through the configured route.

## Phase 7b.9 — Documentation

Update:

- `docs/03-runbooks/secrets-guardrails-monitoring.md` (new): operations runbook for the guardrail-monitoring pipeline, including how to triage each alert
- `docs/01-architecture/08-observability.md`: add a section on the secrets-guardrails subsystem
- `infrastructure/grafana/dashboards/secrets-guardrails.json`: committed
- `infrastructure/alertmanager/rules/secrets-guardrails.yaml`: committed
- PLAN.md: mark Phase 7b ✅
```

---

## Success criteria

- [ ] Promtail scrape config commits and deploys; events labeled correctly
- [ ] Loki retention policy applied; compactor is enforcing 90-day retention
- [ ] Grafana "Secrets Guardrails" dashboard renders all 4 panels with live data
- [ ] Alertmanager rules deployed; severity=critical and severity=high routes verified end-to-end
- [ ] Scrubber sink swap done; OTel pipeline receiving non-secret errors and redacting near-leaks
- [ ] Weekly verification cron runs on schedule; failure path emits `severity=critical`
- [ ] Weekly template-drift cron runs on schedule
- [ ] Documentation committed; PLAN.md updated

---

## Troubleshooting

### "Events appear in Loki without labels"

Promtail's JSON parser stage is misconfigured. Check the pipeline order: `json` stage extracts fields, then `labels` stage promotes them. Ordering matters.

### "Loki isn't honoring per-stream retention"

The compactor must be running, AND `compactor.retention_enabled: true` must be set, AND the global retention period must be greater than or equal to your longest per-stream retention. Otherwise per-stream falls back to the global value.

### "Alertmanager rules don't fire"

Two failure modes: the metric the rule references doesn't exist (check the recording-rule name and that Loki's ruler is producing it), or the routing tree drops it before the receiver. Use Alertmanager's `amtool` to walk the routing tree.

### "Scrubber redacts good content"

The secret-shape regex is too aggressive. Tune in `apps/lib/secrets/scrubber/`; consider a multi-pattern allowlist for known-non-secret strings that match the regex by coincidence.

---

## What's next

[Phase 8 — Privileged Access (Teleport, optional)](./phase-08-teleport.md). If skipping, jump to [Phase 9](./phase-09-hello-world.md).
