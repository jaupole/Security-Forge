# metrics-policy — read-only access to OpenBao's Prometheus metrics
# endpoint. Bound to a periodic token consumed by Prometheus's
# ServiceMonitor `bearerTokenSecret`.
#
# Phase 7d Item 4 (2026-05-02). Replaces the local-edition stopgap
# `telemetry { unauthenticated_metrics_access = true }` on the OpenBao
# listener with first-class token auth — defense-in-depth on top of the
# existing `allow-prometheus-to-openbao-metrics` NetworkPolicy.
#
# Scope:
#   - GET /v1/sys/metrics — the Prometheus-format dump scraped on the
#     ServiceMonitor's 30s interval. Nothing else.

path "sys/metrics" {
  capabilities = ["read"]
}
