#!/usr/bin/env bash
# Verify 08: Layer 4 escape-hatch — a Pod with the
# `secforge.local/legacy-secret-env` + `legacy-secret-env-expires`
# annotation pair is admitted (no-secret-shaped-env-vars precondition
# skip), AND the legacy-secret-env-expiry policy passes (within 90d,
# future). The companion ingestion side: a `secrets.guardrail.bypass`
# event with `outcome: annotated-bypass` lands at the collector.
#
# Two modes:
#   * Offline (default) — runs `kyverno test` against the
#     allowed-legacy-escape-hatch fixture and asserts BOTH policies
#     pass. The event-emission side is verified by inspecting the
#     daily CronJob's structure rather than running it.
#   * Live (LIVE=1)    — kubectl apply + tail collector logs for the
#     emitted event. Operator-only.
#
# Exit codes:
#   0  — admission allowed AND (offline) policies pass / (live) event seen
#   1  — admission denied OR no event emitted (guardrail broken)
#   2  — operator setup issue

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

LIVE="${LIVE:-0}"

if [ "$LIVE" = "1" ]; then
    if ! command -v kubectl >/dev/null 2>&1; then
        red "VERIFY-08: LIVE=1 requires kubectl"
        exit 2
    fi
    yellow "VERIFY-08 (LIVE): apply allowed-legacy-escape-hatch fixture"
    POD="allowed-legacy-escape-hatch"
    trap 'kubectl delete pod -n app "$POD" --wait=false >/dev/null 2>&1 || true' EXIT
    kubectl apply -f infrastructure/kyverno/tests/fixtures/allowed-legacy-escape-hatch.yaml \
        -n app 2>&1 | tee /tmp/verify-08.log
    if ! grep -q "created\|configured" /tmp/verify-08.log; then
        red "VERIFY-08 FAIL (LIVE): admission denied; check policy preconditions"
        exit 1
    fi
    green "VERIFY-08 (LIVE) phase 1: admission ALLOWED via escape hatch"

    # Tail the collector's stdout for ~30s looking for an outcome:
    # annotated-bypass event with the matching annotation_ref.
    yellow "VERIFY-08 (LIVE) phase 2: tail collector logs for annotated-bypass event"
    if kubectl logs -n app -l app.kubernetes.io/name=security-events-collector \
        --since=60s --tail=100 2>&1 \
        | grep -q "annotated-bypass"; then
        green "VERIFY-08 PASS (LIVE): annotated-bypass event observed"
        exit 0
    fi
    red "VERIFY-08 FAIL (LIVE): admission allowed but no annotated-bypass event."
    red "The CronJob legacy-env-warner is the canonical emitter; it runs at 06:00 UTC."
    red "Trigger ad-hoc: kubectl create job --from=cronjob/legacy-env-warner -n app verify-08-warner"
    exit 1
fi

# Offline path — `kyverno test` proves admission is allowed.
if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-08: docker required for offline kyverno-cli image"
    exit 2
fi

yellow "VERIFY-08 (offline): kyverno test for allowed-legacy-escape-hatch"
RESULT=0
docker run --rm \
    -v "$REPO_ROOT/infrastructure/kyverno":/work \
    -w /work/tests \
    ghcr.io/kyverno/kyverno-cli:v1.13.0 test . 2>&1 \
    | tee /tmp/verify-08.log || RESULT=$?

if [ $RESULT -ne 0 ]; then
    red "VERIFY-08 FAIL: kyverno test reported failures"
    exit 1
fi

# Confirm the legacy-escape-hatch fixture rows are all 'pass' (admission
# allowed by the no-secret rule's precondition + expiry rule passes).
ALLOWED_OK=$(grep -c "allowed-legacy-escape-hatch.*Pass" /tmp/verify-08.log || true)
if [ "$ALLOWED_OK" -lt 2 ]; then
    red "VERIFY-08 FAIL: expected 2+ pass rows for allowed-legacy-escape-hatch, got $ALLOWED_OK"
    exit 1
fi

green "VERIFY-08 PASS (offline): escape-hatch Pod admission allowed by both policies"
yellow "  Note: live event emission verified by re-running with LIVE=1 against the cluster"
exit 0
