#!/usr/bin/env bash
# 13 — Trivy Operator (Aqua) for cluster-wide CVE + misconfig + secret scanning.
#
# Reports land as CRs in each workload's namespace:
#   - VulnerabilityReport (CVE matches against installed packages)
#   - ConfigAuditReport
#   - ExposedSecretReport
#   - RbacAssessmentReport
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${TRIVY_OPERATOR_CHART_VER:-0.30.0}"
NS=trivy-system

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/trivy-system/01-namespace.yaml"

# 2. Helm install
"$LIB/install-helm.sh" \
  --release trivy-operator --namespace "$NS" \
  --repo-name aqua --repo-url https://aquasecurity.github.io/helm-charts \
  --chart aqua/trivy-operator --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/trivy-operator.yaml"

echo
echo "✓ Trivy Operator deployed."
echo
echo "Trivy schedules an initial CVE scan of every running workload over"
echo "the next ~5 min. After that, look at the reports:"
echo "  kubectl get vulnerabilityreports -A             # CVE matches"
echo "  kubectl get configauditreports -A               # misconfigs"
echo "  kubectl get exposedsecretreports -A             # leaked creds in images"
echo "  kubectl get rbacassessmentreports -A            # over-privileged RBAC"
echo
echo "High-severity CVEs in any namespace:"
echo "  kubectl get vulnerabilityreports -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.report.summary.criticalCount} CRITICAL, {.report.summary.highCount} HIGH{\"\\n\"}{end}'"
