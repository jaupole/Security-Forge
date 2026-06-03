#!/usr/bin/env bash
# 06 — Istio Ambient (L4 mesh).
#
# Built-in Citadel CA, cluster.local trust domain. Coexists with SPIRE
# (which handles workload identity for app-to-OpenBao auth via
# secforge.platform). SPIRE-as-CA integration is deferred.
#
# Order matters: base CRDs → istiod → CNI → ztunnel.
# All four are idempotent (helm upgrade --install).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${ISTIO_CHART_VER:-1.30.0}"
NS=istio-system

# 1. base — CRDs + cluster-wide resources
"$LIB/install-helm.sh" \
  --release istio-base --namespace "$NS" \
  --repo-name istio --repo-url https://istio-release.storage.googleapis.com/charts \
  --chart istio/base --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/istio-base.yaml"

# 2. istiod — control plane (ambient profile)
"$LIB/install-helm.sh" \
  --release istiod --namespace "$NS" \
  --chart istio/istiod --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/istio-istiod.yaml"

# 3. CNI plugin (ambient mode)
"$LIB/install-helm.sh" \
  --release istio-cni --namespace "$NS" \
  --chart istio/cni --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/istio-cni.yaml"

# 4. ztunnel — L4 dataplane DaemonSet
"$LIB/install-helm.sh" \
  --release ztunnel --namespace "$NS" \
  --chart istio/ztunnel --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/istio-ztunnel.yaml"

# 5. Mesh-wide PeerAuthentication (PERMISSIVE; tighten later)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/istio/peer-auth.yaml"

echo
echo "✓ Istio Ambient deployed."
echo
echo "Verify:"
echo "  kubectl get pods -n istio-system"
echo "  kubectl get peerauthentication -n istio-system"
echo
echo "Enabling ambient on a namespace:"
echo "  kubectl label ns <name> istio.io/dataplane-mode=ambient"
echo
echo "Pods in that namespace will start sending L4 traffic via ztunnel."
echo "Existing pods need a restart to pick up the CNI redirection."
