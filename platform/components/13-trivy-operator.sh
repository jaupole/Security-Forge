#!/usr/bin/env bash
# 13 — Trivy Operator (Aqua) for cluster-wide CVE + misconfig + secret scanning.
#
# Reports land as CRs in each workload's namespace:
#   - VulnerabilityReport (CVE matches against installed packages)
#   - ConfigAuditReport
#   - ExposedSecretReport
#   - RbacAssessmentReport
#
# Runs in ClientServer mode (values: operator.builtInTrivyServer=true): the chart
# also brings up a long-lived `trivy-server` StatefulSet (+ `trivy-service` :4954,
# 5Gi PVC) that holds the vuln DB, and scan Jobs are thin clients against it.
# This is what eliminates the multi-image cache-lock race (ADR-0033). Verify the
# server with: kubectl -n trivy-system rollout status statefulset/trivy-server.
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

# Pinned to the version actually deployed on prod (was 0.30.0, which would have
# DOWNGRADED the live 0.32.1 operator on the next installer run). 2026-06-02.
CHART_VER="${TRIVY_OPERATOR_CHART_VER:-0.32.1}"
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
# ClientServer mode: confirm the built-in trivy-server came up (scan Jobs are
# clients against it; without it every scan fails). See ADR-0033.
kubectl -n "$NS" rollout status statefulset/trivy-server --timeout=300s || \
  echo "WARN: trivy-server StatefulSet not Ready — scans will fail until it is (DB download can take a few min on first boot)" >&2
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
