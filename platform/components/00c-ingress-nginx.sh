#!/usr/bin/env bash
# 00c — ingress-nginx (single ingress controller).
#
# Bare-metal, single-node mode: hostPort exposes :80/:443 on the host.
# See platform/values/ingress-nginx.yaml header for the hostNetwork→
# hostPort rationale (Phase 5 hairpin-routing fix).
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${INGRESS_NGINX_CHART_VER:-4.15.1}"
NS=ingress-nginx

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/ingress-nginx/01-namespace.yaml"

# 2. Default security-headers ConfigMap (consumed by controller.config.add-headers)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/ingress-nginx/02-default-headers-configmap.yaml"

# 2b. Layer-A egress baseline — per-namespace allow (operator-backlog #51).
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/ingress-nginx/03-egress-cluster-internal.yaml"

# 3. Helm install
"$LIB/install-helm.sh" \
  --release ingress-nginx --namespace "$NS" \
  --repo-name ingress-nginx --repo-url https://kubernetes.github.io/ingress-nginx \
  --chart ingress-nginx/ingress-nginx --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/ingress-nginx.yaml"

echo
echo "✓ ingress-nginx deployed."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods"
echo "  kubectl -n $NS get svc                       # ClusterIP only"
echo "  ss -tlnp | grep -E ':80|:443'                # host listening"
echo
echo "Public IP for ingress: 65.21.25.40 (set as publish-status-address)"
