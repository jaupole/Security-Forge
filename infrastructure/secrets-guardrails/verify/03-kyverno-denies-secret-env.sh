#!/usr/bin/env bash
# Verify 03: Layer 4 (admission) — Kyverno `no-secret-shaped-env-vars`
# ClusterPolicy rejects a Pod with a secret-shaped env name in `app` ns.
#
# Two modes:
#   * Offline (default) — runs `kyverno test` against committed fixtures.
#     This is the LLM-runnable path; no live cluster touched.
#   * Live (LIVE=1)     — `kubectl apply --dry-run=server` against the
#     live cluster's admission controller. Operator-only.
#
# Exit codes:
#   0  — Kyverno correctly denied the synthetic violation (offline or live)
#   1  — Kyverno failed to deny (guardrail broken)
#   2  — operator setup issue (docker missing offline; kubectl + kyverno
#        plugin missing live)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

LIVE="${LIVE:-0}"

if [ "$LIVE" = "1" ]; then
    if ! command -v kubectl >/dev/null 2>&1; then
        red "VERIFY-03: LIVE=1 requires kubectl"
        exit 2
    fi
    yellow "VERIFY-03 (LIVE): kubectl apply --dry-run=server"
    if kubectl apply --dry-run=server \
        -f infrastructure/kyverno/tests/fixtures/denied-api-key-env.yaml 2>&1 \
        | tee /tmp/verify-03.log | grep -q "denied"; then
        green "VERIFY-03 PASS (LIVE): Kyverno denied the synthetic STRIPE_API_KEY pod"
        exit 0
    fi
    red "VERIFY-03 FAIL (LIVE): Pod admission was NOT denied"
    red "Check Kyverno is in Enforce mode and the ClusterPolicy is loaded:"
    red "  kubectl get clusterpolicy no-secret-shaped-env-vars -o yaml"
    exit 1
fi

# Offline path — `kyverno test` against the committed fixture suite.
if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-03: docker required for the offline kyverno-cli image"
    exit 2
fi

yellow "VERIFY-03 (offline): kyverno test against committed fixtures"
RESULT=0
docker run --rm \
    -v "$REPO_ROOT/infrastructure/kyverno":/work \
    -w /work/tests \
    ghcr.io/kyverno/kyverno-cli:v1.13.0 test . 2>&1 \
    | tee /tmp/verify-03.log || RESULT=$?

if [ $RESULT -eq 0 ]; then
    green "VERIFY-03 PASS (offline): all kyverno-test cases green (9/9)"
    exit 0
fi
red "VERIFY-03 FAIL (offline): kyverno test reported failures"
red "Re-run with -v 6 to see the engine output:"
red "  docker run --rm -v \$PWD/infrastructure/kyverno:/work -w /work/tests \\"
red "    ghcr.io/kyverno/kyverno-cli:v1.13.0 test . -v 6"
exit 1
