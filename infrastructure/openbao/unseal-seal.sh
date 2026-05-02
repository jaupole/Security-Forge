#!/usr/bin/env bash
# Unseal openbao-seal after a Docker Desktop restart.
#
# Usage:
#   bash infrastructure/openbao/unseal-seal.sh
#
# Reads 3 unseal keys from stdin (one per line, blank line to finish).
# Each key is wiped from the script's memory immediately after use.
#
# This is the routine, post-restart operation. Init is in init-seal.sh
# and runs only once.

set -euo pipefail
NS=openbao
POD=openbao-seal-0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 0. Sanity — pod exists, sealed.
if ! kubectl get pod -n "$NS" "$POD" >/dev/null 2>&1; then
    red "$POD not found in $NS namespace. Is the seal-OpenBao deployed?"
    exit 1
fi

status=$(kubectl exec -n "$NS" "$POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if echo "$status" | grep -q '"sealed": false'; then
    green "openbao-seal is already unsealed. Nothing to do."
    exit 0
fi
if ! echo "$status" | grep -q '"initialized": true'; then
    red "openbao-seal is not initialized. Run init-seal.sh first."
    exit 1
fi

# 1. Read 3 keys from stdin.
yellow ""
yellow "Paste 3 unseal keys, one per line. Press Enter on a blank line to finish."
yellow "(Keys are NOT echoed back. They go straight to bao via stdin.)"
yellow ""

count=0
while [ "$count" -lt 3 ]; do
    if ! IFS= read -r -s key; then
        red "stdin closed before 3 keys read."
        exit 1
    fi
    if [ -z "$key" ]; then
        red "Got blank line at key $((count+1))/3. Aborting."
        exit 1
    fi
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 bao operator unseal "$key" >/dev/null
    unset key
    count=$((count+1))
    green "  ✓ key $count of 3 accepted"
done

# 2. Verify.
status=$(kubectl exec -n "$NS" "$POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1)
if echo "$status" | grep -q '"sealed": false'; then
    green ""
    green "openbao-seal is unsealed. Main OpenBao should auto-unseal within ~10s."
else
    red "Unseal didn't take. status:"
    red "$status"
    exit 1
fi

# 3. Post-unseal cleanup — main OpenBao pods stuck in kubelet backoff.
#
# During the operator's manual-unseal window, main pods (openbao-0/1/2) try
# to reach the seal-pod's Transit endpoint, get back 503 "Vault is sealed",
# exit with code 1. Kubelet restarts them with exponential backoff. By the
# time the operator finishes the 3-key entry, the main pods can be sitting
# on backoff timers of 30s+ — they don't recover quickly even though the
# seal-pod is now healthy. Force-delete them so kubelet recreates immediately.
#
# Until the proper structural fix lands (initContainer on the main OpenBao
# StatefulSet that blocks startup until openbao-seal-0 reports Sealed: false
# — see PLAN.md operator-backlog or post-investigation issue), this is the
# friction-relief workaround.

green ""
green "Waiting 15s for main OpenBao to attempt auto-unseal..."
sleep 15

crashlooping_main=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
    | awk '($3 == "CrashLoopBackOff" || $3 == "Error") && $1 ~ /^openbao-[0-9]+$/ { print $1 }' || true)

if [ -n "$crashlooping_main" ]; then
    yellow ""
    yellow "Main OpenBao pods stuck in kubelet backoff (seal-pod was unavailable on their last start):"
    while IFS= read -r pod; do
        yellow "  - $pod"
    done <<< "$crashlooping_main"
    yellow ""
    while IFS= read -r pod; do
        kubectl delete pod -n "$NS" "$pod" >/dev/null
        green "  ✓ deleted $pod (will restart against now-unsealed seal-pod)"
    done <<< "$crashlooping_main"

    yellow ""
    yellow "Waiting up to 90s for main OpenBao pods to reach Ready..."
    sleep 5  # let kubelet recreate the pods so the wait selector matches
    if kubectl wait --for=condition=Ready pod -n "$NS" \
            -l app.kubernetes.io/instance=openbao \
            --timeout=90s >/dev/null 2>&1; then
        green "  ✓ all main OpenBao pods Ready"
    else
        red ""
        red "Main OpenBao pods didn't reach Ready in 90s. Inspect: kubectl get pods -n $NS"
        red "May indicate a deeper issue (Raft state, NetworkPolicy, etc.). Stopping here so"
        red "the app-namespace cleanup below doesn't restart apps against a broken OpenBao."
        exit 1
    fi
fi

# 4. Post-unseal cleanup — apps that crashlooped during the seal window.
#
# Apps that auth to OpenBao via SPIFFE-JWT-SVID (helloworld-bff, authzen-facade,
# etc.) start trying to bootstrap before the operator has unsealed. They
# accumulate failed login attempts with SVIDs that expire (5min default TTL)
# by the time unseal completes, and end up stuck in CrashLoopBackOff with
# stale SVIDs even after OpenBao is healthy. Force a pod restart so SPIRE
# issues fresh SVIDs and bootstrap succeeds cleanly.
#
# Scope is intentionally limited to the 'app' namespace (where user-facing
# apps live) — broader scopes risk deleting pods that are CrashLooping for
# unrelated reasons.

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
green "Cluster should be fully healthy in ~30s."
green "Verify: kubectl get pods --all-namespaces | grep -v 'Running\\|Completed'"
