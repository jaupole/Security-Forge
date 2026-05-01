# Grafana dashboards runbook

> Architecture: [observability](../01-architecture/08-observability.md). Sources: `infrastructure/grafana/dashboards/*.json`.

Five dashboards are provisioned via ConfigMaps with the `grafana_dashboard=1` label. Grafana's `sidecar.dashboards` provisioner watches the observability namespace and auto-loads them.

## Catalog

| Dashboard | UID | Source JSON | Use it when... |
|---|---|---|---|
| Platform Health | `secforge-platform-health` | `platform-health.json` | quick "is anything broken?" check — pod restarts, non-Running counts, namespace memory |
| Auth events — Keycloak | `secforge-auth-events` | `auth-events.json` | login latency / 5xx investigation; tail Keycloak event log via Loki panel |
| AuthZ checks — SpiceDB | `secforge-authz-checks` | `authz-checks.json` | CheckPermission rate/latency, gRPC errors, cache hit rate |
| Secret access — OpenBao | `secforge-secret-access` | `secret-access.json` | audit log rate, login flows, locked users, audit failures |
| Service mesh — Istio Ambient | `secforge-service-mesh` | `service-mesh.json` | ztunnel TCP connection state, mesh throughput, istiod xDS |

URLs (replace base with your local DNS):
- `https://grafana.secforge.local/d/secforge-platform-health/`
- `https://grafana.secforge.local/d/secforge-auth-events/`
- `https://grafana.secforge.local/d/secforge-authz-checks/`
- `https://grafana.secforge.local/d/secforge-secret-access/`
- `https://grafana.secforge.local/d/secforge-service-mesh/`

## Adding or updating a dashboard

1. **Edit the JSON.** Either:
   - Edit `infrastructure/grafana/dashboards/<name>.json` directly, OR
   - Open the dashboard in Grafana → Settings → JSON Model → make changes interactively → "Apply" → copy the JSON back into the file. (Grafana's UI is editable: the chart provisions dashboards as `editable: false`, but in Grafana 11+ "Save" still produces a JSON delta you can paste back.)
2. **Re-apply.** From the project root:
   ```bash
   bash infrastructure/observability/apply-dashboards.sh
   ```
   The script enumerates `*.json` files, wraps each in a ConfigMap named `grafana-dashboard-<basename>` with the `grafana_dashboard=1` label, and applies via `kubectl apply -f -`.
3. **Wait ~30s.** Grafana's sidecar polls every ~10s for ConfigMap changes. The reload-API call (`POST /api/admin/provisioning/dashboards/reload`) fails from inside the cluster because the sidecar resolves `grafana.secforge.local` via `/etc/hosts` to 127.0.0.1, which doesn't bind in-pod — but file-watch is independent of that, so the dashboard appears anyway. The sidecar errors are noisy but harmless.
4. **Verify in Grafana** at the dashboard URL above.

## Conventions for new dashboards

- Set `uid` to `secforge-<short-name>` so the URL is stable across redeploys.
- Set `tags` to include `secforge` plus a domain tag (`auth`, `authz`, `mesh`, `secrets`, `platform`).
- Set `editable: false` on the dashboard root — committed JSON is the source of truth.
- Reference datasources by `uid`: `prometheus`, `loki`, `tempo` (set in `02-grafana-ingress.yaml` / `grafana-datasources-extra` ConfigMap).
- Default to `refresh: "30s"` and time range `now-1h to now`.

## Common pitfalls

- **PromQL label name surprises.** Promtail emits Loki labels using the short K8s names (`namespace`, `pod`, `app`, `container`), NOT the full `app.kubernetes.io/*` form. Queries like `{app_kubernetes_io_name="helloworld-bff"}` will silently match nothing. Use `{app="helloworld-bff"}`.
- **Quarkus metric naming.** Keycloak (Quarkus base) uses `http_server_requests_seconds_*` and `agroal_*`, not `keycloak_*`. There are very few `keycloak_*`-prefixed metrics in the modern Keycloak — most go through Quarkus's standard exporter.
- **Tempo tag-search lag.** Newly arrived traces take a few seconds to appear in `service.name` tag values. If the trace shows in a TraceQL search but not in the tag dropdown, wait ~30s.
- **Grafana 11 panel deprecations.** The legacy `graph` panel type is gone; use `timeseries`. Old dashboards from upstream snippets may need conversion.

## How dashboards interact with alerts

The alert rules in `infrastructure/observability/13-alerting-rules.yaml` use the same metrics the dashboards visualize. If an alert fires, the matching dashboard panel will show the offending series highlighted. The mapping:

| Alert | Dashboard panel |
|---|---|
| `KeycloakHTTP5xxRate` | Auth events → "HTTP request rate (by outcome)" |
| `KeycloakDBPoolExhausted` | Auth events → "DB pool — active / available" |
| `SpiceDBCheckLatencyHigh` | AuthZ checks → "CheckPermission latency p50/p95/p99" |
| `SpiceDBGRPCErrorRate` | AuthZ checks → "gRPC error rate (by code)" |
| `OpenBaoLockedUsers` | Secret access → "Locked users" |
| `OpenBaoAuditFailures` | Secret access → "Audit log failures / sec" |
| `IstioTCPConnectionFailureSpike` | Service mesh → "ztunnel TCP connections" |
| `OpenBaoSealed` | Platform health (and the Operator backlog item — see [openbao-seal-unseal.md](./openbao-seal-unseal.md)) |
| `PodCrashLooping` | Platform health → "Pod restarts" |
| `NamespaceMemoryHigh` | Platform health → "Namespace memory" |
