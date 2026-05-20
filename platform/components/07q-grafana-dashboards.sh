#!/usr/bin/env bash
# 07q — SecForge custom Grafana dashboards.
#
# Installs the SecForge-specific Grafana dashboards as ConfigMaps in the
# observability namespace. Grafana's `sidecar.dashboards` provisioner
# (kube-prometheus-stack chart) picks up any ConfigMap labeled
# `grafana_dashboard=1` in that namespace and reloads within ~30s.
#
# Source-of-truth JSON: platform/manifests/observability/dashboards/*.json
# Dashboards:
#   auth-events        — Keycloak HTTP rate/latency, JVM heap
#   authz-checks       — SpiceDB CheckPermission rate/latency, gRPC errors
#   platform-health    — cross-component health overview
#   secret-access      — OpenBao audit req/sec, logins, locked users
#   secrets-guardrails — legacy-secret-env escape-hatch admissions
#   service-mesh       — ztunnel TCP + istiod metrics
#
# The dashboards reference datasources by stable UID (`prometheus`, `loki`),
# which match the live Grafana's datasource UIDs.
#
# Run AFTER 07e-prometheus.sh (brings up Grafana) and 07h-grafana-datasources.sh.
# Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
DASH_DIR="$PLATFORM_DIR/manifests/observability/dashboards"

NS=observability

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ -d "$DASH_DIR" ] || { red "ERROR: $DASH_DIR not found"; exit 1; }

shopt -s nullglob
dashboards=("$DASH_DIR"/*.json)
[ ${#dashboards[@]} -gt 0 ] || { red "ERROR: no dashboard JSON files in $DASH_DIR"; exit 1; }

for f in "${dashboards[@]}"; do
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

cat <<EOF

✓ ${#dashboards[@]} SecForge Grafana dashboards installed.

Grafana's dashboard sidecar reloads them within ~30s. They appear under
the "SecForge" folder at https://grafana.<your-domain>/dashboards.
EOF
