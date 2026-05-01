#!/usr/bin/env bash
# Phase 6.2 — install Istio Ambient (built-in Citadel CA).
# Order matters: base CRDs → istiod (control plane) → CNI plugin → ztunnel L4.
# Reapplying is idempotent (helm upgrade --install).
set -euo pipefail

NS=istio-system
CHART_VER="${ISTIO_CHART_VER:-1.29.2}"
HERE="$(cd "$(dirname "$0")" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

green "==> 1/4 istio/base ($CHART_VER)"
helm upgrade --install istio-base istio/base \
    --version "$CHART_VER" \
    -n "$NS" --create-namespace \
    -f "$HERE/01-base-values.yaml" \
    --wait

green "==> 2/4 istio/istiod ($CHART_VER, ambient profile)"
helm upgrade --install istiod istio/istiod \
    --version "$CHART_VER" \
    -n "$NS" \
    -f "$HERE/02-istiod-values.yaml" \
    --wait

green "==> 3/4 istio/cni ($CHART_VER, ambient)"
helm upgrade --install istio-cni istio/cni \
    --version "$CHART_VER" \
    -n "$NS" \
    -f "$HERE/03-cni-values.yaml" \
    --wait

green "==> 4/4 istio/ztunnel ($CHART_VER)"
helm upgrade --install ztunnel istio/ztunnel \
    --version "$CHART_VER" \
    -n "$NS" \
    -f "$HERE/04-ztunnel-values.yaml" \
    --wait

green ""
green "==> verify"
kubectl get pods -n "$NS"
