# Phase 7 — Observability

> **Navigation:** ⬅ [Previous: Phase 6b-1 — API Auth Pattern](./phase-06b-api-pattern.md) (or Phase 6.10b if running 7 before 6b-1) · [Next: Phase 7b/7c/7d (parallel) → Fix-after-07 → Phase 8/9](./phase-07b-post-6b2-monitoring.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 6
> **Blocks:** Phase 7b · 7c · 7d · Fix-after-07 · Phase 9 · Phase 10 · Phase 11 (every later phase needs the observability stack to verify itself)
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ✅ Complete (Sessions 1–4, 2026-04-29 → 2026-05-01). All sub-phases shipped: 7.0 / 7.1 / 7.2 (Wazuh) / 7.3 / 7.4 / 7.5 / 7.6 / 7.7 / 7.8 / 7.9 / 7.10. The 7-day SPIFFE-CSI startupProbe soak runs as background-monitoring; not phase-blocking. Three follow-ups carried to Phase 7d.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 4 days

**Prerequisites:** Phases 1-6 complete.

---

## Goal of this phase

Stand up the observability stack: SIEM (Wazuh), metrics (Prometheus + Grafana), logs (Loki), traces (Tempo). Wire every component built so far to send its telemetry. Locally we run a slimmed Wazuh; the cloud edition would scale it out.

---

## What you (the human) need to do first

1. Confirm Phases 1-6 are complete. The observability stack is consumer of all the platform components built before it.
2. Allocate a bit more memory if you're tight — Wazuh alone wants ~2 GB.

---

## Keycloak clients required (verify or create BEFORE starting)

Grafana and Wazuh dashboard each need OIDC federation to Keycloak. **Confirm clients exist before running the prompt.**

| Client ID | Realm | Confidential | Redirect URIs | Created by |
|---|---|---|---|---|
| `grafana` | `platform` | yes (client-secret) | `https://grafana.secforge.local/login/generic_oauth` | This phase. Provision via `infrastructure/keycloak/clients/grafana.sh` (clone openbao.sh template). |
| `wazuh-dashboard` | `platform` | yes (client-secret) | per Wazuh dashboard OIDC docs | This phase. Provision via `infrastructure/keycloak/clients/wazuh-dashboard.sh`. |

Both clients need:
- Default scopes include **`roles`** (so `realm_access.roles` is in tokens)
- Realm role mapping for **`platform_admin`** (already created in Phase 5) → maps to Grafana Admin / Wazuh admin role

Lesson from Phase 5: don't rely on inline kcadm calls in the Claude Code prompt. Provision via committed scripts so fresh-cluster bootstraps are reproducible.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 7 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-07-observability.md before doing anything.

Your task is to deploy the full observability stack and wire every component to send logs, metrics, and traces.

## Phase 7.0 — Pre-flight carry-ins

Three small items carried forward from Phase 5/6 follow-ups land here. They're cheap individually but collectively de-risk Phase 7's verification (especially `realm_access.roles`, which Phase 7.4's Loki ingest is needed to debug). Do these BEFORE Phase 7.1's design pass.

### 7.0.a — SPIFFE-CSI startupProbe fix (~half day)

Source: Phase 5 follow-up #6. Local-only race: every Docker Desktop restart yields a 60–90s window where the `csi.spiffe.io` driver isn't yet registered with kubelet, while workload pods try to mount the SPIFFE-CSI volume. Pods backoff exponentially; JWT-SVIDs minted by the spiffe-helper init container expire (5-min TTL) before the main container starts; CrashLoop ensues. Manual workaround today is `kubectl delete pod`. Proper fix: add a `startupProbe` to every SPIFFE-consuming workload so kubelet keeps retrying the mount instead of escalating to liveness kills.

Each workload's startupProbe should be tuned to whatever readiness signal it already exposes — port-listen check, /healthz endpoint, or socket responsiveness via `nc -U` or similar. Before writing the probe for a given workload, inspect its existing readinessProbe (if any) and reuse the same check. If the workload has no readiness signal, fall back to `test -S /spiffe-workload-api/<actual-socket-name>` after grepping the workload's mount config for the SPIFFE-CSI volume mount path. Do NOT copy a hardcoded path from this prompt — verify it for each workload individually, since SPIFFE-CSI driver versions name the socket file differently (`spire-agent.sock`, `agent.sock`, etc.).

The startupProbe parameters stay constant across all workloads:

  failureThreshold: 30
  periodSeconds: 10
  # 30 * 10s = 5 minute grace; comfortably exceeds observed cold-boot delay

Apply to these 6 workloads (all are confirmed SPIFFE-CSI consumers today):

- `openbao-0`, `openbao-1`, `openbao-2` (StatefulSet, `openbao` namespace)
- `openbao-seal-0` (StatefulSet, `openbao` namespace)
- `helloworld-bff` (Deployment, `app` namespace)
- `authzen-facade` (Deployment, `app` namespace; both replicas inherit)

**Soak verification target**: zero post-boot manual `kubectl delete pod` operations against any SPIFFE-CSI consumer for 7 consecutive days, tracked via the platform-health Grafana dashboard's pod-restart panel (built in Phase 7.7). Restart Docker Desktop at least 3 times during the soak window so the startupProbe path is actually exercised.

### 7.0.b — `realm_access.roles` claim plumbing debug (~1 day)

Source: Phase 5 follow-up #1. The OpenBao `admin` OIDC role currently binds on `preferred_username=jason.upole` instead of `realm_access/roles=platform_admin`. Keycloak's `roles` scope is set to Default on the openbao client and the `realm roles` mapper has Add-to-ID-token + userinfo enabled, but `realm_access.roles` still doesn't appear in the claims OpenBao captures.

**Sequencing constraint**: do this AFTER Phase 7.4 (Loki + Promtail) goes live, because the debug path requires reading Keycloak's structured event logs and OpenBao's audit logs side-by-side at the moment of the OIDC callback. Without Loki/Promtail you'd be doing this with `kubectl logs` tail-following, which is the same blind-spot setup that produced the original gap.

**Success path**: rebind the OpenBao `admin` role to `realm_access/roles=platform_admin` so a second `platform_admin` user inherits admin without per-user binding. Verify by adding a throwaway second user to `platform_admin` and confirming `bao login -method=oidc` works for them.

**Fallback path**: if Keycloak's userinfo response truly doesn't surface `realm_access.roles` (vs. surfacing it but OpenBao not capturing it correctly), document the userinfo behavior in `docs/03-runbooks/keycloak-operations.md`, leave the `preferred_username` binding in place, and switch this follow-up to "wait for second admin or 90-day trigger."

**90-day fallback escalation trigger**: 2026-07-29. If unresolved by that date, raise priority regardless of other re-evaluation criteria from PLAN.md Phase 5 follow-up #1.

### 7.0.c — OIDC CLI redirect URI fix (~30 min)

Source: Phase 5 follow-up #3. The OpenBao `admin` OIDC role's `allowed_redirect_uris` only lists UI callbacks (`https://bao.secforge.local/...`); the bao CLI's local listener (`http://localhost:8250/oidc/callback`) is not whitelisted, so `bao login -method=oidc` fails. Worked around historically by getting the admin token via the UI.

Add `http://localhost:8250/oidc/callback` to BOTH:

- `infrastructure/openbao/configure-auth-oidc.sh` — append to the `admin` role's `allowed_redirect_uris` list
- `infrastructure/keycloak/clients/openbao.sh` — append to the `openbao` client's Valid Redirect URIs

Re-apply both scripts. Verify by running `bao login -method=oidc` from the WSL host and completing the browser callback to localhost:8250 successfully.

## Phase 7.1 — Design

Document in docs/01-architecture/08-observability.md:
- SIEM: Wazuh (slimmed for local — 1 manager, 1 indexer, 1 dashboard pod each)
- Metrics: kube-prometheus-stack (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics)
- Logs: Loki + Promtail (or Vector — pick Promtail for simplicity)
- Traces: OpenTelemetry Collector → Tempo
- Long-term log archive: MinIO bucket `wazuh-archive`

## Phase 7.2 — Deploy Wazuh (slimmed)

Use the official Wazuh Helm chart with these adjustments for local:
- 1 manager replica (instead of 3+)
- 1 indexer replica with 4Gi heap (instead of 3+ with 8Gi each)
- 1 dashboard replica
- Storage: 20Gi PVC for indexer
- Wazuh agent: DaemonSet on the single node
- Expose dashboard at https://wazuh.secforge.local via Ingress with NetworkPolicy restricting to localhost only

Configure to:
- Receive syslog/JSON over TCP from in-cluster sources
- Apply CIS Kubernetes benchmarks
- Apply MITRE ATT&CK mapping rules
- Forward critical alerts to STDOUT (locally — no email config; cloud would route to PagerDuty/Slack)

Document in docs/03-runbooks/wazuh-operations.md.

## Phase 7.3 — Deploy kube-prometheus-stack

Use the official chart:
- Prometheus: 1 replica, 14-day retention, 20Gi PVC
- Alertmanager: 1 replica
- Grafana: 1 replica, expose at https://grafana.secforge.local with NetworkPolicy
- node-exporter: DaemonSet
- kube-state-metrics
- Pre-configured dashboards for Kubernetes + node health

Configure Prometheus ServiceMonitors for our platform components:
- Keycloak: scrape /metrics on management port
- SpiceDB: scrape gRPC metrics
- OpenBao: scrape /v1/sys/metrics?format=prometheus
- Istio: scrape ztunnel and waypoint metrics
- BFF: scrape /metrics

Grafana auth: OIDC federated to Keycloak (admin = my passkey login). Map Keycloak `platform_admin` role to Grafana Admin.

## Phase 7.4 — Deploy Loki + Promtail

- Loki: single-binary deployment locally (not microservices mode), 14-day retention, 10Gi PVC
- Promtail: DaemonSet, scraping all pod logs
- Loki backed by MinIO bucket `loki-chunks` (create the bucket if needed)
- Configure Loki datasource in Grafana so logs are queryable from the same UI

## Phase 7.5 — Deploy Tempo + OpenTelemetry Collector

- Tempo: single-binary, 7-day retention, 10Gi PVC
- Tempo backed by MinIO bucket `tempo-traces`
- OpenTelemetry Collector: DaemonSet, receives OTLP gRPC and HTTP from apps, forwards to Tempo
- Configure Tempo datasource in Grafana
- Set up trace-to-logs correlation (Grafana feature: clicking a trace span jumps to related Loki logs by trace_id)

## Phase 7.6 — Wire components to ship telemetry

For each platform component, configure:

### Keycloak
- JSON event logger to STDOUT (already done in Phase 3) → Promtail picks up
- ServiceMonitor enabled
- OpenTelemetry tracing enabled, OTLP endpoint to the collector

### SpiceDB
- OpenTelemetry tracing already enabled in Phase 4 — verify endpoint
- Audit logs to STDOUT → Promtail
- ServiceMonitor enabled

### OpenBao
- Audit log device → STDOUT (already done in Phase 5)
- Telemetry config: OpenTelemetry → collector
- ServiceMonitor enabled

### Istio
- Access logs as JSON → Promtail
- Tracing → OpenTelemetry collector → Tempo
- ServiceMonitor for ztunnel and istiod metrics

### BFF
- Already instrumented in Phase 6 — verify traces appear in Tempo

## Phase 7.7 — Dashboards

Create initial Grafana dashboards (commit JSON to infrastructure/grafana/dashboards/):

1. **Auth events**: Keycloak login successes/failures over time, by realm, by user
2. **AuthZ checks**: SpiceDB CheckPermission rate, latency, allow/deny ratio
3. **Secret access**: OpenBao reads/writes per policy, rejected requests
4. **Service mesh**: request rate, error rate, latency, top callers, by-service mTLS coverage
5. **Platform health**: pod restarts, OOM kills, PV usage, certificate expiry

Use ConfigMap-based dashboard provisioning so they're version-controlled.

## Phase 7.8 — Alerts

Configure Alertmanager with these alerts (locally route to a Slack-ish webhook if you have one, otherwise just to logs — but write the rules so cloud migration is just changing the receiver):

- High auth failure rate (potential brute force or credential stuffing)
- OpenBao seal status (immediate page if main openbao is sealed unexpectedly)
- Certificate expiring in <14 days
- SpiceDB high latency (>500ms p99)
- Pod CrashLoopBackOff in any platform namespace
- Istio policy denial spike (could indicate an attack or a broken policy)

Document in docs/03-runbooks/alerts.md what each alert means and what to do.

## Phase 7.9 — Verify end-to-end

- Trigger a login at https://app.secforge.local
- Verify in Wazuh dashboard: see the login event from Keycloak
- Verify in Loki via Grafana: see Keycloak's structured log of the event
- Verify in Tempo via Grafana: see the trace from BFF → Keycloak → callback chain
- Verify in Prometheus via Grafana: see the request count tick up

If all four show the event correlated by trace_id or username, observability is working.

## Phase 7.10 — Documentation

Update:
- docs/01-architecture/08-observability.md
- docs/03-runbooks/wazuh-operations.md
- docs/03-runbooks/alerts.md
- docs/03-runbooks/grafana-dashboards.md
- infrastructure/grafana/dashboards/ (committed JSON)

## Constraints

- Wazuh dashboard, Grafana — both behind NetworkPolicy + Keycloak auth
- No `:latest` image tags
- Resource limits on every component (the indexer especially)
- All components opt into ServiceMonitor scraping — no manual /metrics polling
- Trace_id propagated through the BFF → backend → SpiceDB call chain
```

---

## Success criteria

- [ ] Wazuh deployed; agent collecting; dashboard reachable; OIDC auth works
- [ ] Prometheus + Grafana deployed; OIDC auth; dashboards showing data
- [ ] Loki + Promtail deployed; logs from all platform pods searchable
- [ ] Tempo + OTel Collector deployed; traces from BFF visible
- [ ] Auth event correlation (login → Wazuh + Loki + Tempo + Prometheus all show it)
- [ ] At least 5 dashboards committed and rendering
- [ ] Alerting rules defined; documentation explains each
- [ ] Documentation updated; PLAN.md updated

---

## Troubleshooting

### "Wazuh indexer pod OOMKilled"
The default 4Gi heap might be insufficient if you have lots of agents. Locally with 1 agent it's overkill; reduce to 2Gi. If still OOM, the indexer's storage might be corrupted — delete the PVC and let it reinitialize (data loss; OK locally).

### "Prometheus has no targets"
ServiceMonitor namespace selector wrong. By default kube-prometheus-stack's Prometheus only watches its own namespace. Set `serviceMonitorSelectorNilUsesHelmValues: false` and `serviceMonitorNamespaceSelector: {}` in values.

### "Traces don't show up in Tempo"
Verify OTLP endpoint in BFF env vars matches the collector's service. Check collector logs for ingestion errors. Tempo's discovery sidecar may take a minute to register new traces.

---

## What's next

If Phase 6b-2 is also done, run [Phase 7b — Post-6b-2 Monitoring Wire-up](./phase-07b-post-6b2-monitoring.md) next to wire the secret-guardrail emission from 6b-2 into this stack. [Phase 7c — Istio SPIRE-as-CA cutover + STRICT](./phase-07c-istio-spire-ca-and-strict.md) and [Phase 7d — Rotation and housekeeping batch](./phase-07d-rotation-housekeeping.md) (BFF private_key_jwt rotation + SpiceDB datastore_uri → database-engine) are independent of each other and of 7b — run in any order after Phase 7.

After those, [Phase 8 — Privileged Access (Teleport, optional)](./phase-08-teleport.md). If skipping, jump to [Phase 9](./phase-09-hello-world.md).
