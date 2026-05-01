#!/usr/bin/env bash
# Apply all Phase 7.7 Grafana dashboards as ConfigMaps.
#
# Source files:    infrastructure/grafana/dashboards/*.json
# Discovery:       Grafana's sidecar.dashboards provisioner picks up any
#                  ConfigMap labeled grafana_dashboard=1 in the
#                  observability namespace and reloads within ~30s.

set -euo pipefail

NS=observability
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_DIR="$HERE/../grafana/dashboards"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

for f in "$DASH_DIR"/*.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .json)"
    cm_name="grafana-dashboard-$base"

    green "==> $cm_name"
    kubectl create configmap "$cm_name" \
        --namespace "$NS" \
        --from-file="$base.json=$f" \
        --dry-run=client -o yaml | \
        kubectl label -f - --local -o yaml \
            --overwrite \
            grafana_dashboard=1 \
            secforge.platform/component=observability | \
        kubectl apply -f - >/dev/null
done

green ""
green "All dashboards applied. Grafana sidecar reloads within ~30s."
green "URLs:"
for f in "$DASH_DIR"/*.json; do
    base="$(basename "$f" .json)"
    uid=$(python3 -c "import json,sys; print(json.load(open('$f')).get('uid',''))" 2>/dev/null)
    [ -n "$uid" ] && green "  https://grafana.secforge.local/d/$uid/"
done
