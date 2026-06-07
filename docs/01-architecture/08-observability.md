# Observability

> **Production note.** Written for the local edition; the observability stack below is unchanged in production. Substrate deltas: ingress is the **Istio gateway**; the admin UIs (`grafana.secforge.dev`, `wazuh.secforge.dev`) are **tailnet-only** (not ingress-nginx + hosts file). See [PLAN.md](../../PLAN.md) and [00-overview.md](./00-overview.md).

> Companion runbooks (built alongside Phase 7): [Wazuh operations](../03-runbooks/wazuh-operations.md), [Grafana dashboards](../03-runbooks/grafana-dashboards.md), [Alerts](../03-runbooks/alerts.md).
> Stack choices: per-component rows in [CLAUDE.md § Architecture stack](../../CLAUDE.md).

The observability stack consumes everything built in Phases 1–6. Four pillars, all running in-cluster:

| Pillar | Component | Storage backend | Status (2026-05-01) |
|---|---|---|---|
| SIEM | Wazuh (manager + indexer + dashboard) | Indexer PVC + MinIO `wazuh-archive` for long-term | ⬜ Phase 7.2 — deferred to next session |
| Metrics | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) | Prometheus PVC (14d retention) | ✅ live; 29 targets up |
| Logs | Loki (single-binary) + Promtail DaemonSet | MinIO `loki-chunks` (14d retention) | ✅ live; all platform pods scraped |
| Traces | OpenTelemetry Collector (DaemonSet) → Tempo (single-binary) | MinIO `tempo-traces` (7d retention) | ✅ live; 4 services flowing (BFF, AuthZEN, SpiceDB, Keycloak) |

Cloud-edition delta: nothing changes except Loki/Tempo backing buckets move from MinIO to S3 and Wazuh scales out from 1+1+1 to 3+3+1. Prometheus replaces single-replica with HA pair.

**Verification:** end-to-end checks (synthetic traffic across each pillar) were carried by the retired local edition's `verify-e2e.sh`; a platform equivalent is not yet in place.

---

## Goals

1. **Everything emits.** Every platform component (Keycloak, SpiceDB, OpenBao, Istio, BFF, AuthZEN-facade) ships logs to Loki, metrics to Prometheus via ServiceMonitor, and (where useful) traces to Tempo via OTel.
2. **Single pane.** Grafana is the entry point — metrics + logs + traces queryable from one UI, correlated by `trace_id` across pillars.
3. **Authz federated.** Grafana and Wazuh dashboard both authenticate against Keycloak (OIDC, `platform_admin` realm role → admin). No standalone admin accounts.
4. **NetworkPolicy-isolated.** Both UIs reachable only via ingress-nginx; no direct pod-to-pod scrape from outside `observability` namespace except for the explicit ServiceMonitor flows.
5. **Cloud-portable.** Same charts, same ServiceMonitors, same dashboards. Migration touches storage backends and Wazuh replica counts only.

---

## Wazuh — slimmed for local

Cloud edition runs 3+ Wazuh managers, 3+ indexer nodes, 1 dashboard. Local runs **1 + 1 + 1**:

- Manager: 1 replica, 1 GB heap. Receives Wazuh agent traffic over TCP/1514 and dashboard queries over 55000.
- Indexer: 1 replica, 4 GB heap (locally bumped down to 2 GB if memory-pressured), 20 GB PVC.
- Dashboard: 1 replica, exposed at `https://wazuh.secforge.dev`.

Wazuh agent runs as a DaemonSet on the single node and audits:
- File integrity in `/etc`, `/var/log`, `/usr/bin`
- CIS Kubernetes benchmark (rules shipped in the Wazuh image)
- MITRE ATT&CK mapping rules (built-in)
- Syslog/JSON over TCP from in-cluster sources (Keycloak event JSON, OpenBao audit JSON)

Critical alerts forward to STDOUT locally. Cloud edition routes to PagerDuty/Slack via Wazuh's integration framework — same rules, swapped receiver.

NetworkPolicy on `wazuh.secforge.dev`: ingress only from ingress-nginx; no east-west reach to Wazuh dashboard from other namespaces.

---

## kube-prometheus-stack

Standard upstream chart. Local sizing:

- Prometheus: 1 replica, 14-day retention, 20 GB PVC
- Alertmanager: 1 replica
- Grafana: 1 replica, OIDC auth federated to Keycloak
- node-exporter: DaemonSet
- kube-state-metrics: 1 replica

ServiceMonitors live in component namespaces (Keycloak, SpiceDB, OpenBao, Istio, `app`) and use the label `release: kps` (the chart's `fullnameOverride`) so the chart's Prometheus picks them up. Chart values set `serviceMonitorSelectorNilUsesHelmValues: false` and `serviceMonitorNamespaceSelector: {}` so cross-namespace scraping works without per-monitor allowlisting.

**OpenBao /metrics gating:** the listener carries `telemetry { unauthenticated_metrics_access = true }` for the local edition; the existing `allow-prometheus-to-openbao-metrics` NetworkPolicy is the L4 gate. Cloud migration **must** flip to token-auth via a `metrics-policy` token in a Secret consumed by the ServiceMonitor's `bearerTokenSecret` — tracked in Phase 7d.

**ztunnel** has no Service in Istio Ambient (DaemonSet only), so a `PodMonitor` rather than a `ServiceMonitor` scrapes its `/metrics` on port 15020.

Targets:

| Source | Endpoint | What it gives us |
|---|---|---|
| Keycloak | `/metrics` on management port | login rate, token issuance, realm-role lookups |
| SpiceDB | `/metrics` (gRPC reflection) | CheckPermission rate/latency, allow/deny ratio |
| OpenBao | `/v1/sys/metrics?format=prometheus` | secret reads/writes per policy, seal status |
| Istio (ztunnel + istiod) | their built-in `/stats/prometheus` | mTLS coverage, request rate/latency, AuthorizationPolicy denies |
| BFF / AuthZEN-facade | `/metrics` | DPoP-bound session count, AuthZEN evaluation latency |

Alertmanager rules (high-level — full list in [alerts.md](../03-runbooks/alerts.md)): high auth failure rate, OpenBao unexpectedly sealed, cert expiring <14d, SpiceDB p99 >500ms, CrashLoopBackOff in any platform namespace, Istio policy denial spike.

Grafana auth: `grafana` Keycloak client (confidential, per-client `private_key_jwt` in cloud edition; client-secret locally for simplicity). Realm role `platform_admin` → Grafana Admin via Keycloak's role-mapper config.

---

## Loki + Promtail

Loki runs in single-binary mode (not microservices), 14-day retention, 10 GB PVC. Backed by MinIO bucket `loki-chunks` for chunk storage; the index uses BoltDB locally (cloud uses S3+DynamoDB equivalents).

Promtail DaemonSet scrapes every pod's STDOUT log via the kubelet log directory. No Promtail-side filtering — Loki retains everything for 14 days; queries from Grafana filter by namespace, pod, label.

Grafana datasource for Loki is provisioned via ConfigMap so logs are queryable from the same UI as metrics. Trace-to-logs correlation: the OTel collector adds `trace_id` to log records when Promtail's pipeline detects W3C trace-context in app logs (apps emit `trace_id` as a top-level JSON field).

---

## Tempo + OpenTelemetry Collector

Tempo: single-binary, 7-day retention, 10 GB PVC, MinIO bucket `tempo-traces`. Long enough for incident debugging; cloud edition keeps 30 days.

OTel Collector: DaemonSet, receives OTLP gRPC + HTTP from apps, forwards to Tempo. Apps configure `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4317` via env (set by Helm values for chart-managed components, by Deployment env for `app`-namespace pods).

Trace propagation chain (login flow, end-to-end): browser → BFF → Keycloak → BFF callback → AuthZEN-facade → SpiceDB. Each hop carries the W3C `traceparent` header forward. The same trace_id appears in Loki via the Promtail JSON pipeline and in Prometheus exemplars (where supported), letting Grafana's "trace-to-logs" feature jump from a Tempo span to the corresponding Loki entries with one click.

**OTLP endpoint env-var caveat (Go SDK):** `OTEL_EXPORTER_OTLP_ENDPOINT` for the Go OTel SDK's gRPC exporter requires the `http://` scheme prefix (`http://otel-collector.observability.svc.cluster.local:4317`). The bare `host:port` form fails with `delegating_resolver: invalid target address`. Java/Quarkus and the Helm-managed components (SpiceDB) accept both. All deployments now use the `http://` form.

**Tracing deferred for OpenBao:** OpenBao 2.5 does not have a native OTLP exporter (its `telemetry` stanza supports Prometheus + datadog + statsd only). Phase 7d revisits when upstream support lands. OpenBao is a leaf in the request graph (called once at BFF bootstrap, not per-request), so missing it from request traces is acceptable.

---

## MinIO buckets

Three new buckets created during Phase 7 (the existing `secforge-minio` MinIO release adds them via `mc mb`):

- `loki-chunks` — chunk storage for Loki
- `tempo-traces` — trace storage for Tempo
- `wazuh-archive` — long-term archive for Wazuh indexer

Each gets a per-bucket service-account credential issued via OpenBao's KV secrets engine; cloud edition swaps to MinIO STS or S3 IAM.

---

## OIDC federation

Two new Keycloak clients in the `platform` realm (provisioned in Phase 7 via committed scripts following the Path A pattern — see [feedback memory: kcadm Path A pattern]):

| Client | Confidential | Redirect | Realm-role mapping |
|---|---|---|---|
| `grafana` | yes (client-secret) | `https://grafana.secforge.dev/login/generic_oauth` | `platform_admin` → Grafana `Admin` |
| `wazuh-dashboard` | yes (client-secret) | per Wazuh OIDC docs | `platform_admin` → Wazuh `admin` |

Both use the `roles` default scope so `realm_access.roles` ships in tokens. Same passkey (or TOTP fallback during 2026-09 → 2026-12 interim, per ADR-0007) drives every admin login.

---

## What we did NOT do (and why)

- **No multi-cluster mesh observability.** Single-node local; no point.
- **No long-term metrics with Thanos / Mimir.** 14-day Prometheus retention is enough for local; Mimir runs in cloud edition.
- **No external incident management** (PagerDuty/Opsgenie/etc.). Alertmanager's local receiver writes to STDOUT; the cloud edition swaps the receiver only.
- **No Wazuh active-response.** The agent reports findings but does not auto-quarantine or auto-block. Active-response design is a Wazuh-runbook decision separate from the architecture.
- **No e-BPF tracing layer (Pixie / Cilium-Hubble).** Out of scope for Phase 7. Istio's L4 metrics give us per-flow visibility; eBPF would be a Phase 12+ investment.
