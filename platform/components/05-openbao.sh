#!/usr/bin/env bash
# 05 — OpenBao verification (bootstrap-seal + bootstrap-main run separately).
#
# This script does NOT perform the irreversible init steps. The seal and main
# OpenBao initializations capture one-time-displayed unseal/recovery keys that
# the operator MUST capture offline. Those run via:
#   bash 05a-openbao-bootstrap-seal.sh
#   bash 05b-openbao-bootstrap-main.sh
#
# This script verifies state and prints what's pending.

set -euo pipefail

NS=openbao

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  cat <<EOF
ℹ openbao namespace doesn't exist yet.

Run the bootstrap scripts in order (each prompts for offline-backup confirmation):
  bash $(dirname "$0")/05a-openbao-bootstrap-seal.sh
  bash $(dirname "$0")/05b-openbao-bootstrap-main.sh
EOF
  exit 0
fi

# Seal status
seal_init=false
seal_sealed=true
if kubectl -n "$NS" get pod openbao-seal-0 >/dev/null 2>&1; then
  s=$(kubectl exec -n "$NS" openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
  echo "$s" | grep -q '"initialized":[[:space:]]*true' && seal_init=true
  echo "$s" | grep -q '"sealed":[[:space:]]*false' && seal_sealed=false
fi

# Main status
main_init=false
main_sealed=true
if kubectl -n "$NS" get pod openbao-0 >/dev/null 2>&1; then
  s=$(kubectl exec -n "$NS" openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
  echo "$s" | grep -q '"initialized":[[:space:]]*true' && main_init=true
  echo "$s" | grep -q '"sealed":[[:space:]]*false' && main_sealed=false
fi

echo "OpenBao state:"
echo "  seal: deployed=$(kubectl -n $NS get pod openbao-seal-0 >/dev/null 2>&1 && echo yes || echo no)  initialized=$seal_init  sealed=$seal_sealed"
echo "  main: deployed=$(kubectl -n $NS get pod openbao-0 >/dev/null 2>&1 && echo yes || echo no)  initialized=$main_init  sealed=$main_sealed"
echo

if ! $seal_init; then
  echo "Next: bash $(dirname "$0")/05a-openbao-bootstrap-seal.sh"
  exit 0
fi
if $seal_sealed; then
  echo "openbao-seal is initialized but SEALED. Unseal it manually with 3 of 5 Shamir keys:"
  echo "  for KEY in <key1> <key2> <key3>; do"
  echo "    kubectl exec -n $NS openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao operator unseal \$KEY"
  echo "  done"
  exit 0
fi
if ! $main_init; then
  echo "Next: bash $(dirname "$0")/05b-openbao-bootstrap-main.sh"
  exit 0
fi

echo "✓ OpenBao seal + main both initialized + unsealed."
echo "  Configuration (engines, auth methods, policies) is the Phase 5 follow-up."
