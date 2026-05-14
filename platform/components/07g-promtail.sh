#!/usr/bin/env bash
# 07g — Promtail DaemonSet (logs → Loki).
#
# Pre-condition: 07f (Loki) deployed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${PROMTAIL_CHART_VER:-6.17.1}"
NS=observability

"$LIB/install-helm.sh" \
  --release promtail --namespace "$NS" \
  --repo-name grafana --repo-url https://grafana.github.io/helm-charts \
  --chart grafana/promtail --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/promtail.yaml"

echo
echo "✓ Promtail deployed (DaemonSet, one pod per node)."
echo "Sanity:"
echo "  kubectl -n $NS get ds promtail"
echo "  kubectl -n $NS logs ds/promtail --tail=20"
