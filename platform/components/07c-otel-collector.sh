#!/usr/bin/env bash
# 07c — OpenTelemetry Collector (DaemonSet) → forwards OTLP to Tempo.
#
# What this does:
#   1. Apply NetworkPolicy allowing OTLP ingress from keycloak ns
#      (today's only producer; Phase 7-rest will extend to app/spicedb/istio).
#   2. Helm install otel-collector.
#
# Pre-conditions:
#   - 07b-tempo.sh complete (Tempo Service reachable in observability ns).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${OTEL_CHART_VER:-0.158.1}"  # 0.153.0 -> 0.158.1 2026-06-10 (pentest CVE refresh)
NS=observability

# 1. NetworkPolicy
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/04-otel-ingress-np.yaml"

# 2. Helm install
"$LIB/install-helm.sh" \
  --release otel-collector --namespace "$NS" \
  --repo-name open-telemetry --repo-url https://open-telemetry.github.io/opentelemetry-helm-charts \
  --chart open-telemetry/opentelemetry-collector --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/otel-collector.yaml"

echo
echo "✓ OpenTelemetry Collector deployed (DaemonSet)."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods -l app.kubernetes.io/name=opentelemetry-collector"
echo "  kubectl -n $NS logs ds/otel-collector --tail=30"
echo
echo "Endpoint for OTLP producers:"
echo "  gRPC: otel-collector.observability.svc.cluster.local:4317"
echo "  HTTP: otel-collector.observability.svc.cluster.local:4318"
