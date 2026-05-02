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
MAIN_PODS=(openbao-2 openbao-1 openbao-0)   # roll order: followers first

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
green "==> 0/5 seal-OpenBao is up and unsealed"

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
green "==> 1/5 seal-OpenBao root accepted"

# ──────────────────────────────────────────────────────────────────────
# 2. Mint a fresh 24h Transit unseal token.
# ──────────────────────────────────────────────────────────────────────
NEW_TOKEN=$(kubectl exec -n "$NS" "$SEAL_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$SEAL_ROOT" \
    bao token create -policy=unseal-policy -ttl=24h -renewable=true -format=json \
    2>/dev/null | jq -r '.auth.client_token')
unset SEAL_ROOT

if [ -z "$NEW_TOKEN" ] || [ "$NEW_TOKEN" = "null" ]; then
    red "Token mint failed. Confirm the root you pasted is the seal-OpenBao root,"
    red "not the main OpenBao root, and that unseal-policy exists in seal-OpenBao."
    exit 1
fi
green "==> 2/5 fresh Transit token minted (24h TTL, renewable)"

# ──────────────────────────────────────────────────────────────────────
# 3. Patch the openbao-transit-token K8s Secret.
# ──────────────────────────────────────────────────────────────────────
kubectl -n "$NS" patch secret openbao-transit-token \
    --type=merge \
    -p "{\"stringData\":{\"token\":\"$NEW_TOKEN\"}}" >/dev/null
unset NEW_TOKEN
green "==> 3/5 openbao-transit-token Secret patched"

# ──────────────────────────────────────────────────────────────────────
# 4. Re-render the seal block via apply-main.sh.
#    The watchdog inside apply-main.sh may "bail" reporting too many
#    restarts on openbao-0 — that's a timeout, not a failure. The seal
#    block has already been re-rendered; step 5 finishes recovery.
# ──────────────────────────────────────────────────────────────────────
yellow "==> 4/5 running apply-main.sh to re-render the seal block"
yellow "    (if it bails reporting 'too many restarts on openbao-0', that's"
yellow "     a benign timeout — step 5 below finishes the recovery)"
if ! bash "$HERE/apply-main.sh"; then
    yellow "    apply-main.sh exited non-zero — proceeding to pod roll anyway"
    yellow "    per the documented 2026-05-01 recovery sequence."
fi

# ──────────────────────────────────────────────────────────────────────
# 5. Roll the main pods (OnDelete) so they pick up the new seal block.
# ──────────────────────────────────────────────────────────────────────
green "==> 5/5 rolling main OpenBao pods (followers first)"
for pod in "${MAIN_PODS[@]}"; do
    if kubectl get pod -n "$NS" "$pod" >/dev/null 2>&1; then
        yellow "    deleting $pod"
        kubectl delete pod -n "$NS" "$pod" --wait=true --timeout=120s || true
    else
        yellow "    $pod not present, skipping"
    fi
done

# ──────────────────────────────────────────────────────────────────────
# Verify — block until all 3 main pods are Ready, then exit.
# ──────────────────────────────────────────────────────────────────────
green ""
green "Waiting for all 3 main OpenBao pods to reach Ready (timeout 180s)..."
green ""

if kubectl wait --for=condition=Ready pod \
        -n "$NS" \
        -l app.kubernetes.io/instance=openbao \
        --timeout=180s 2>&1; then
    green ""
    green "All 3 main OpenBao pods are Ready. Recovery complete."
    kubectl get pod -n "$NS" -l app.kubernetes.io/instance=openbao
    exit 0
else
    red ""
    red "Timed out waiting for Ready. Current pod state:"
    kubectl get pod -n "$NS" -l app.kubernetes.io/instance=openbao >&2
    red ""
    red "Inspect logs: kubectl logs -n $NS openbao-0 -c openbao --tail=30"
    exit 1
fi
