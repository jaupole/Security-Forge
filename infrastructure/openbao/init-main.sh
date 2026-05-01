#!/usr/bin/env bash
# Phase 5.3 (continuation) — initialize the main OpenBao.
#
# Pre-conditions:
#   - openbao-seal is unsealed
#   - openbao-{0,1,2} are Running and Ready (sealed but reachable)
#   - openbao-seal-block Secret has the right Transit token
#
# Steps:
#   1. bao operator init -recovery-shares=5 -recovery-threshold=3
#      Recovery keys (not unseal keys) — auto-unseal handles the seal,
#      recovery keys are only used for break-glass operations like
#      `bao operator generate-root` and re-keying the seal.
#   2. PRINT 5 recovery keys + initial root token to STDOUT once.
#   3. Confirm sealed=false on all 3 replicas (auto-unseal worked).
#   4. Confirm Raft membership (3 voters).

set -euo pipefail
NS=openbao
POD=openbao-0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 "$@"
}

# 0. Idempotency.
status_json=$(bao bao status -format=json 2>&1 || true)
if echo "$status_json" | grep -q '"initialized": true'; then
    red "Main OpenBao is already initialized. Refusing to re-init."
    red "If you genuinely want a clean slate, delete the PVCs and re-deploy:"
    red "  kubectl -n $NS delete statefulset openbao"
    red "  kubectl -n $NS delete pvc -l app.kubernetes.io/name=openbao"
    red "  bash apply-main.sh && bash init-main.sh"
    exit 1
fi

# 1. Init.
green "==> bao operator init -recovery-shares=5 -recovery-threshold=3"
init_out=$(bao bao operator init \
    -recovery-shares=5 \
    -recovery-threshold=3 \
    -format=json 2>&1)

mapfile -t RECOVERY_KEYS < <(jq -r '.recovery_keys_b64[]' <<<"$init_out")
ROOT_TOKEN=$(jq -r '.root_token' <<<"$init_out")

if [ "${#RECOVERY_KEYS[@]}" -ne 5 ] || [ -z "$ROOT_TOKEN" ]; then
    red "init didn't produce expected output. Raw:"
    red "$init_out"
    exit 1
fi

# 2. Print to stdout once.
yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " main OpenBao — INITIAL ROOT TOKEN + RECOVERY KEYS (5/3)"
yellow ""
yellow "  Initial root token:  $ROOT_TOKEN"
yellow ""
yellow "  Recovery key 1/5:    ${RECOVERY_KEYS[0]}"
yellow "  Recovery key 2/5:    ${RECOVERY_KEYS[1]}"
yellow "  Recovery key 3/5:    ${RECOVERY_KEYS[2]}"
yellow "  Recovery key 4/5:    ${RECOVERY_KEYS[3]}"
yellow "  Recovery key 5/5:    ${RECOVERY_KEYS[4]}"
yellow ""
yellow " Action required:"
yellow "   - Copy ALL 6 values into your offline password manager NOW."
yellow "   - Recovery keys are NOT unseal keys. The pods auto-unseal via"
yellow "     openbao-seal's Transit. Recovery keys are used for break-glass:"
yellow "     bao operator generate-root, bao operator rekey, etc."
yellow "   - The initial root token will be REVOKED after Phase 5.6 (once"
yellow "     OIDC auth is verified). Until then it is the only credential"
yellow "     that can configure auth methods, secrets engines, policies."
yellow "═════════════════════════════════════════════════════════════════════"
yellow ""

# 3. Wait for auto-unseal across all 3.
green "==> Waiting for all 3 replicas to auto-unseal"
for i in 0 1 2; do
    until kubectl exec -n "$NS" "openbao-$i" -c openbao -- \
            env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 \
            | grep -q '"sealed": false'; do
        sleep 2
    done
    green "    openbao-$i sealed=false"
done

# 4. Verify Raft cluster membership.
green "==> Raft membership"
bao env BAO_TOKEN="$ROOT_TOKEN" bao operator raft list-peers 2>&1 | tail -10

green ""
green "Phase 5.3 init complete. Main OpenBao is unsealed via Transit."
green "Next: capture the 6 secrets above offline, then proceed to"
green "      Phase 5.7+5.11 (audit + secrets engines)."
