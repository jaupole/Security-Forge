#!/usr/bin/env bash
# 07h — Apply Grafana datasource ConfigMaps for Loki + Tempo.
#
# Picked up by Grafana's `sidecar.datasources` provisioner via the
# `grafana_datasource: "1"` label. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/08-grafana-datasources-extra.yaml"

echo
echo "✓ Grafana extra datasources applied."
echo "  Grafana sidecar polls every 10s; the Tempo + Loki datasources should"
echo "  appear in Grafana → Connections → Data sources within 30s."
