#!/usr/bin/env bash
# 12 — Kyverno admission policy engine.
#
# Installs Kyverno controllers in the `kyverno` namespace. Policies
# (ClusterPolicy + Policy CRDs) are applied separately by 12b-kyverno-policies.sh.
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${KYVERNO_CHART_VER:-3.8.0}"
NS=kyverno

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/kyverno/01-namespace.yaml"

# 2. Helm install
"$LIB/install-helm.sh" \
  --release kyverno --namespace "$NS" \
  --repo-name kyverno --repo-url https://kyverno.github.io/kyverno \
  --chart kyverno/kyverno --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/kyverno.yaml"

echo
echo "✓ Kyverno installed."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods"
echo "  kubectl -n $NS get validatingwebhookconfigurations"
echo
echo "Next: bash 12b-kyverno-policies.sh (apply ClusterPolicies)"
