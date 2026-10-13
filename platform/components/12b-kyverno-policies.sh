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

# policies-cel/ holds the policies.kyverno.io (CEL) policies: ValidatingPolicy,
# MutatingPolicy, ImageValidatingPolicy and the PolicyException (which must
# live in the kyverno namespace — Kyverno honours exceptions only in
# --exceptionNamespace). The kyverno.io/v1 ClusterPolicies were retired on
# 2026-10-13 (kyverno.io/v1 is removed in Kyverno 1.20).
green "==> apply policies.kyverno.io (CEL) policies"
for f in "$PLATFORM_DIR/manifests/kyverno/policies-cel/"*.yaml; do
  "$LIB/apply-manifest.sh" "$f"
done

# Weekly guardrail self-test CronJob (operator-backlog #54) — proves the
# no-secret-shaped-env-vars policy still rejects a secret-shaped Pod.
green "==> apply guardrail self-test CronJob"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/kyverno/07-guardrail-selftest.yaml"

echo
green "✓ Kyverno policies applied."
echo
echo "Inspect:"
echo "  kubectl get validatingpolicies,mutatingpolicies,imagevalidatingpolicies,policyexceptions.policies.kyverno.io"
echo "  kubectl get policyreport -A | head    # per-namespace audit reports"
echo "  kubectl get clusterpolicyreport       # cluster-scope audit reports"
echo
echo "New validating policies ship with validationActions: [Deny]; to soak one, set [Audit] in its manifest."
echo
echo "Image-signature verification (05-image-signature-verification.yaml):"
echo "  verify-image-signature-secforge  Enforce  SecForge images (keyless)"
echo "  verify-image-signature-vendors   Audit    CloudNativePG + SPIFFE"
echo "  6 vendor images ship no signature — see operator-backlog #41."
echo "  Registry creds + egress are wired by 12c-kyverno-image-verify-creds.sh."
