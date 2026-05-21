#!/usr/bin/env bash
# 12b — Apply Kyverno ClusterPolicies.
#
# All policies start in `validationFailureAction: Audit` mode. After ~1
# week of clean PolicyReport output, flip to Enforce one policy at a time.
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Wait for Kyverno's webhook to be ready before applying policies.
green "==> wait for kyverno admission controller webhook ready"
kubectl -n kyverno wait --for=condition=available deployment/kyverno-admission-controller --timeout=120s 2>&1 | tail -1
sleep 5

green "==> apply ClusterPolicies (all in Audit mode initially)"
for f in "$PLATFORM_DIR/manifests/kyverno/policies/"*.yaml; do
  "$LIB/apply-manifest.sh" "$f"
done

echo
green "✓ Kyverno policies applied (Audit mode)."
echo
echo "Inspect:"
echo "  kubectl get clusterpolicy"
echo "  kubectl get policyreport -A | head    # per-namespace audit reports"
echo "  kubectl get clusterpolicyreport       # cluster-scope audit reports"
echo
echo "Soak for ~1 week. Then flip one policy at a time:"
echo "  kubectl patch clusterpolicy <name> --type=merge -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
echo
echo "Image-signature verification (05-image-signature-verification.yaml):"
echo "  verify-image-signature-secforge  Enforce  SecForge images (keyless)"
echo "  verify-image-signature-vendors   Audit    CloudNativePG + SPIFFE"
echo "  6 vendor images ship no signature — see operator-backlog #41."
echo "  Registry creds + egress are wired by 12c-kyverno-image-verify-creds.sh."
