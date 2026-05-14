#!/usr/bin/env bash
# 02 — SPIRE (workload identity)
#
# Trust domain: ${SPIFFE_TRUST_DOMAIN} (= secforge.platform — decoupled from public DNS).
# Provides X.509 + JWT SVIDs to all platform workloads via spiffe-csi-driver.
#
# Installs in this order:
#   1. spire-crds chart (CRDs for ClusterSPIFFEID + ControllerManagerConfig + ClusterFederatedTrustDomain)
#   2. spire chart (server StatefulSet + agent DaemonSet + spiffe-csi-driver + controller-manager + OIDC discovery)
#   3. ClusterSPIFFEID registrations for keycloak / spicedb / openbao / app / istio-system namespaces
#
# Pre-req: components/02-spire-bootstrap-ca.sh must have been run to load
# the `spire-upstream-ca` Secret. This script refuses to proceed without it.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

# Pre-flight: ensure upstream CA Secret exists
if ! kubectl get secret spire-upstream-ca -n spire >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: spire-upstream-ca Secret not found in 'spire' namespace.

Run the CA bootstrap first:
  bash ~/secforge/platform/components/02-spire-bootstrap-ca.sh

That script generates the upstream CA, displays it for offline backup,
and loads it into the Secret. It is irreversible — only run once.
EOF
  exit 1
fi

# Source globals so version pins are visible (helm version pinning happens in lib)
# shellcheck disable=SC1091
source "$PLATFORM_DIR/globals.env"

# 1. SPIRE CRDs (must come before main spire chart)
"$LIB/install-helm.sh" \
  --release spire-crds \
  --namespace spire \
  --repo-name spiffe --repo-url https://spiffe.github.io/helm-charts-hardened \
  --chart spiffe/spire-crds \
  --version 0.5.0 \
  --values "$PLATFORM_DIR/values/spire-crds.yaml"

# 2. SPIRE main chart
"$LIB/install-helm.sh" \
  --release spire \
  --namespace spire \
  --chart spiffe/spire \
  --version 0.28.4 \
  --values "$PLATFORM_DIR/values/spire.yaml"

# 3. ClusterSPIFFEID registrations (no envsubst needed; trust domain is templated by SPIRE controller)
echo ">>> applying ClusterSPIFFEID registrations"
kubectl apply -f "$PLATFORM_DIR/manifests/spire/cluster-spiffe-ids.yaml"

# Wait for spire-server to be Ready
echo ">>> Waiting for spire-server to be Ready..."
kubectl rollout status statefulset/spire-server -n spire --timeout=300s

echo
echo "✓ SPIRE deployed."
echo
echo "Verify:"
echo "  kubectl get pods -n spire"
echo "  kubectl get clusterspiffeids"
echo "  kubectl logs -n spire statefulset/spire-server --tail=30"
