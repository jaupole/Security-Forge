#!/usr/bin/env bash
# Rotate the Transit unseal token after a >24h cluster outage.
#
# Usage:
#   bash infrastructure/openbao/rotate-transit-token.sh
#
# When to run:
#   - Main OpenBao pods are CrashLoopBackOff after a Docker Desktop restart,
#     AND seal-OpenBao reports `Sealed: false`,
#     AND main pod log shows `403 permission denied` against
#     /v1/transit/encrypt/unseal.
#   - This means the 24h Transit auto-unseal token expired while the
#     cluster was cold. Recovery is mint-new-token + patch Secret + roll
#     main pods.
#
# Prerequisites:
#   - seal-OpenBao initial root token (printed by Phase 5.2 init-seal.sh,
#     stored offline in your password manager — NOT the 5 unseal keys,
#     NOT the main OpenBao root).
#   - Read from stdin (no echo). Wiped from memory after use.
#
# Reference: docs/03-runbooks/openbao-recovery.md § Rotate the Transit
# unseal token.

set -euo pipefail

NS=openbao
SEAL_POD=openbao-seal-0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

HERE="$(cd "$(dirname "$0")" && pwd)"

# ──────────────────────────────────────────────────────────────────────
# 0. Sanity — seal-OpenBao must be up + unsealed before we mint anything.
# ──────────────────────────────────────────────────────────────────────
if ! kubectl get pod -n "$NS" "$SEAL_POD" >/dev/null 2>&1; then
    red "$SEAL_POD not found in $NS. Run apply-seal.sh first."
    exit 1
fi

seal_status=$(kubectl exec -n "$NS" "$SEAL_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if ! echo "$seal_status" | grep -q '"sealed": false'; then
    red "$SEAL_POD is sealed. Run unseal-seal.sh first; this script assumes"
    red "the seal-OpenBao is already unsealed."
    exit 1
fi
green "==> 0/4 seal-OpenBao is up and unsealed"

# ──────────────────────────────────────────────────────────────────────
# 1. Read seal-OpenBao initial root from stdin (no echo).
# ──────────────────────────────────────────────────────────────────────
yellow ""
yellow "Paste the seal-OpenBao initial root token (NOT main OpenBao root)."
yellow "(Not echoed back. Wiped from memory after use.)"
yellow ""

if ! IFS= read -r -s SEAL_ROOT; then
    red "stdin closed before token read."
    exit 1
fi
if [ -z "$SEAL_ROOT" ]; then
    red "Empty token. Aborting."
    exit 1
fi
green "==> 1/4 seal-OpenBao root accepted"

# ──────────────────────────────────────────────────────────────────────
# 2. Mint a fresh 24h Transit unseal token.
# ──────────────────────────────────────────────────────────────────────
NEW_TOKEN=$(kubectl exec -n "$NS" "$SEAL_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token create -policy=unseal-policy -period=720h -format=json \
    2>/dev/null | jq -r '.auth.client_token')
unset SEAL_ROOT

if [ -z "$NEW_TOKEN" ] || [ "$NEW_TOKEN" = "null" ]; then
    red "Token mint failed. Confirm the root you pasted is the seal-OpenBao root,"
    red "not the main OpenBao root, and that unseal-policy exists in seal-OpenBao."
    exit 1
fi
# Phase 7d Item 3: -period=720h matches init-seal.sh — periodic tokens
# auto-renew on every use (= every main OpenBao transit-unseal call at
# boot). 30-day idle ceiling vs the prior 24h. See ADR-0009.
green "==> 2/4 fresh Transit token minted (period=720h, auto-renews on use)"

# ──────────────────────────────────────────────────────────────────────
# 3. Patch the openbao-transit-token K8s Secret.
# ──────────────────────────────────────────────────────────────────────
kubectl -n "$NS" patch secret openbao-transit-token \
    --type=merge \
    -p "{\"stringData\":{\"token\":\"$NEW_TOKEN\"}}" >/dev/null
unset NEW_TOKEN
green "==> 3/4 openbao-transit-token Secret patched"

# ──────────────────────────────────────────────────────────────────────
# 4. Re-render the seal block + roll stale main pods + wait Ready.
#    apply-main.sh detects the seal-block content change, force-rolls any
#    existing main pods follower-first so they re-read the new token, and
#    blocks until all 3 are Ready (per-pod restart-delta + 10 min deadline).
# ──────────────────────────────────────────────────────────────────────
green "==> 4/4 running apply-main.sh (re-renders seal block, rolls stale pods, waits Ready)"
if ! bash "$HERE/apply-main.sh"; then
    red ""
    red "apply-main.sh failed. Current pod state:"
    kubectl get pod -n "$NS" -l app.kubernetes.io/instance=openbao >&2
    red ""
    red "Inspect logs: kubectl logs -n $NS openbao-0 -c openbao --tail=30"
    exit 1
fi
green ""
green "All 3 main OpenBao pods are Ready."
kubectl get pod -n "$NS" -l app.kubernetes.io/instance=openbao

# ──────────────────────────────────────────────────────────────────────
# Post-recovery app cleanup — restart apps that crashlooped during
# the multi-day outage. Same logic as unseal-seal.sh step 3.
#
#    In the multi-day-pause case, apps have been failing for >24h, not
#    just minutes — they're definitely sitting on stale SVIDs by now.
#    Force a restart so SPIRE issues fresh ones and bootstrap succeeds.
#
#    Scope is intentionally limited to the 'app' namespace.
# ──────────────────────────────────────────────────────────────────────
crashlooping=$(kubectl get pods -n app --no-headers 2>/dev/null \
    | awk '$3 == "CrashLoopBackOff" { print $1 }' || true)

if [ -n "$crashlooping" ]; then
    yellow ""
    yellow "Found CrashLooping pods in 'app' namespace (almost certainly stale SVIDs):"
    while IFS= read -r pod; do
        yellow "  - $pod"
    done <<< "$crashlooping"
    yellow ""
    while IFS= read -r pod; do
        kubectl delete pod -n app "$pod" >/dev/null
        green "  ✓ deleted $pod (will restart with fresh SVID)"
    done <<< "$crashlooping"
fi

green ""
green "Recovery complete. Cluster should be fully healthy in ~30s."
green "Verify: kubectl get pods --all-namespaces | grep -v 'Running\\|Completed'"
exit 0
