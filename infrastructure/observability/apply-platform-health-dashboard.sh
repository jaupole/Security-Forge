#!/usr/bin/env bash
# Apply the platform-health Grafana dashboard ConfigMap.
#
# Source: infrastructure/grafana/dashboards/platform-health.json
# Picked up by Grafana's sidecar.dashboards provisioner via the
# grafana_dashboard=1 label.
#
# This wraps the JSON in a kubectl-create-configmap one-liner because
# embedding a 250-line dashboard JSON inside a YAML string field is
# fragile (escaping, indentation, JSON-vs-YAML conflicts). kubectl's
# --from-file delivers the right shape directly.

set -euo pipefail

NS=observability
CM_NAME=grafana-dashboard-platform-health
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_FILE="$HERE/../grafana/dashboards/platform-health.json"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

[ -f "$DASH_FILE" ] || { echo "dashboard JSON not found: $DASH_FILE" >&2; exit 1; }

green "==> applying $CM_NAME ConfigMap to $NS namespace"
kubectl create configmap "$CM_NAME" \
    --namespace "$NS" \
    --from-file="platform-health.json=$DASH_FILE" \
    --dry-run=client -o yaml | \
    kubectl label -f - --local -o yaml \
        --overwrite \
        grafana_dashboard=1 \
        secforge.platform/component=observability | \
    kubectl apply -f -

green ""
green "Dashboard installed. Grafana sidecar picks it up within ~30s."
green "View: https://grafana.secforge.local/d/secforge-platform-health/platform-health"
