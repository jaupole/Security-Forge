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
    green "Verify: kubectl get pod -n openbao -l app.kubernetes.io/instance=openbao"
else
    red "Unseal didn't take. status:"
    red "$status"
    exit 1
fi
