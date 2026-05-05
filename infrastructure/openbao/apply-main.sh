#!/usr/bin/env bash
# Phase 5.3 — deploy main OpenBao with Transit auto-unseal.
#
# Pre-conditions:
#   - openbao-seal is unsealed (bash apply-seal.sh + init-seal.sh ran)
#   - Secret openbao/openbao-transit-token exists with key `token`
#     (the Phase 5.2 Transit token from init-seal.sh)
#
# Steps:
#   1. Apply NetworkPolicies (main openbao + Postgres ingress in app ns)
#   2. Helm install/upgrade `openbao` release
#   3. Wait for the 3-replica StatefulSet to come up; pods auto-unseal
#      via the seal-OpenBao's Transit endpoint
#   4. Tell the operator to run init-main.sh next
#
# Idempotent: re-runs upgrade in place.

set -euo pipefail
NS=openbao
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Pre-condition checks.
if ! kubectl -n "$NS" get secret openbao-transit-token >/dev/null 2>&1; then
    red "Secret openbao/openbao-transit-token not found."
    red "Run apply-seal.sh + init-seal.sh first, then create the Secret:"
    red "  kubectl -n openbao create secret generic openbao-transit-token \\"
    red "    --from-literal=token=<the-Transit-token-from-init-seal.sh>"
    exit 1
fi

if ! kubectl -n "$NS" get pod openbao-seal-0 >/dev/null 2>&1; then
    red "openbao-seal-0 not found. Run apply-seal.sh first."
    exit 1
fi

seal_status=$(kubectl exec -n "$NS" openbao-seal-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if ! echo "$seal_status" | grep -q '"sealed": false'; then
    red "openbao-seal is sealed. Run unseal-seal.sh first, then re-run this."
    exit 1
fi

green "==> Applying main-openbao NetworkPolicies"
kubectl apply -f "$HERE/06-networkpolicies-main.yaml"
kubectl apply -f "$HERE/07-postgres-app-ingress.yaml"

# Render the seal HCL block from openbao-transit-token Secret.
# We do this server-side via apply rather than committing the rendered
# block to Git — the token is the only sensitive value, but committing
# even-an-encrypted seal block invites copy-paste mistakes.
green "==> Rendering openbao-seal-block Secret with the Transit token"
TRANSIT_TOKEN=$(kubectl get secret -n "$NS" openbao-transit-token \
    -o jsonpath='{.data.token}' | base64 -d)
SEAL_HCL=$(cat <<EOF
seal "transit" {
  address         = "https://openbao-seal.openbao.svc.cluster.local:8200"
  token           = "${TRANSIT_TOKEN}"
  disable_renewal = "false"
  key_name        = "unseal"
  mount_path      = "transit/"
  tls_ca_cert     = "/openbao/tls/openbao-tls/ca.crt"
  tls_skip_verify = "false"
}
EOF
)
# Capture the previous block (if any) BEFORE we delete it. If the content
# changed, any running main pods are pinned to the old token and will keep
# 403'ing against transit/encrypt/unseal until they're rolled — the
# StatefulSet's OnDelete updateStrategy doesn't restart them on its own
# when the referenced Secret changes.
OLD_SEAL_BLOCK=$(kubectl get secret -n "$NS" openbao-seal-block \
    -o jsonpath='{.data.seal\.hcl}' 2>/dev/null | base64 -d 2>/dev/null || true)
kubectl -n "$NS" delete secret openbao-seal-block --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic openbao-seal-block \
    --from-literal=seal.hcl="${SEAL_HCL}" >/dev/null
kubectl -n "$NS" label secret openbao-seal-block \
    app.kubernetes.io/name=openbao \
    secforge.platform/component=openbao \
    secforge.platform/purpose=seal-config-with-token \
    --overwrite >/dev/null
SEAL_BLOCK_CHANGED=false
if [ -n "${OLD_SEAL_BLOCK:-}" ] && [ "${OLD_SEAL_BLOCK}" != "${SEAL_HCL}" ]; then
    SEAL_BLOCK_CHANGED=true
fi
unset TRANSIT_TOKEN SEAL_HCL OLD_SEAL_BLOCK

green "==> Helm install/upgrade openbao (main)"
helm upgrade --install openbao openbao/openbao \
    --namespace "$NS" \
    --version 0.27.2 \
    --values "$HERE/04-openbao-values.yaml" \
    --timeout 5m

# If the seal block changed (token rotation, etc.) and main pods exist,
# force-roll them follower-first so they re-read the new block. Without
# this the watchdog below would wait forever — the existing pods are stuck
# on the old token and won't restart on their own under OnDelete.
if [ "${SEAL_BLOCK_CHANGED:-false}" = "true" ]; then
    green "==> Seal block changed — rolling existing main pods (followers first)"
    for i in 2 1 0; do
        if kubectl get pod -n "$NS" "openbao-$i" >/dev/null 2>&1; then
            green "  deleting openbao-$i"
            kubectl delete pod -n "$NS" "openbao-$i" --wait=false 2>/dev/null || true
        fi
    done
fi

green "==> Waiting for openbao-{0,1,2} pods (sealed→unsealed via Transit)"
# Watchdog policy:
#   - Per-pod baseline restartCount; only delta restarts (those occurring
#     while WE are watching) count against the threshold. Pre-existing
#     restarts from a stale seal block are not failures of THIS run.
#   - Re-baseline if restartCount goes down (pod was recreated externally).
#   - Overall 10-minute deadline as a backstop against silent stalls.
WATCH_DEADLINE=$(($(date +%s) + 600))
for i in 0 1 2; do
    until kubectl get pod -n "$NS" "openbao-$i" >/dev/null 2>&1; do
        sleep 2
    done
    R_BASE=$(kubectl get pod -n "$NS" "openbao-$i" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
    R_BASE=${R_BASE:-0}
    until kubectl get pod -n "$NS" "openbao-$i" \
            -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
        R=$(kubectl get pod -n "$NS" "openbao-$i" \
            -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
        R=${R:-0}
        # Pod was recreated externally — restartCount went backwards. Reset baseline.
        [ "$R" -lt "$R_BASE" ] && R_BASE=$R
        P=$(kubectl get pod -n "$NS" "openbao-$i" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        DELTA=$((R - R_BASE))
        echo "  openbao-$i: phase=$P restarts=$R (+$DELTA since watch start)"
        if [ "$(date +%s)" -ge "$WATCH_DEADLINE" ]; then
            red "openbao-$i did not become Ready within 10 minutes; bailing"
            kubectl logs -n "$NS" "openbao-$i" --previous --tail=30 2>&1 | tail -20
            exit 1
        fi
        if [ "$DELTA" -ge 3 ]; then
            red "openbao-$i restarted $DELTA times since watch started; bailing"
            kubectl logs -n "$NS" "openbao-$i" --previous --tail=30 2>&1 | tail -20
            exit 1
        fi
        sleep 5
    done
    green "  openbao-$i Ready"
done

green ""
green "Main OpenBao pods are up. They are sealed-but-Ready until init."
green "Next: bash infrastructure/openbao/init-main.sh"
green ""
green "init-main.sh will:"
green "  - run 'bao operator init -recovery-shares=5 -recovery-threshold=3'"
green "  - print the 5 recovery keys + initial root token to STDOUT once"
green "  - confirm auto-unseal worked"
green ""
green "BEFORE running init-main.sh: be ready to copy 5 recovery keys + root"
green "into your offline password manager."
