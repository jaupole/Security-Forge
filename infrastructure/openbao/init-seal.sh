#!/usr/bin/env bash
# Phase 5.2 (continuation) — initialize openbao-seal:
#   1. bao operator init -key-shares=5 -key-threshold=3
#   2. Capture and PRINT the 5 unseal keys + initial root token
#   3. Unseal with 3 of the 5 keys
#   4. Login as root, enable Transit, create the `unseal` aes256-gcm96 key
#   5. Write `unseal-policy` (allow only encrypt/decrypt with the unseal key)
#   6. Mint a TTL=24h renewable token bound to the policy — this is what
#      the main OpenBao will use as its `seal "transit"` token
#   7. PRINT the Transit unseal token
#
# Idempotent guard: if openbao-seal is already initialized, this script
# refuses to re-run (re-initializing destroys all state). Use unseal-seal.sh
# for routine post-restart unsealing.

set -euo pipefail
NS=openbao
POD=openbao-seal-0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# bao() — wrapper that runs `bao` inside the seal pod with TLS skip-verify.
# We pass BAO_SKIP_VERIFY=1 via env (rather than the CLI flag) because
# the flag must precede positional args, and the wrapper would put it in
# the wrong place for `operator unseal <KEY>`.
bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 bao "$@"
}

# 0. Sanity check.
status_json=$(kubectl exec -n "$NS" "$POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if echo "$status_json" | grep -q '"initialized": true'; then
    red "openbao-seal is already initialized. Refusing to re-init (would wipe state)."
    red "If you genuinely want a clean slate, delete the PVC and re-deploy:"
    red "  kubectl -n $NS delete statefulset openbao-seal"
    red "  kubectl -n $NS delete pvc data-openbao-seal-0"
    red "  bash apply-seal.sh && bash init-seal.sh"
    exit 1
fi

# 1. Init.
green "==> bao operator init -key-shares=5 -key-threshold=3"
init_out=$(bao operator init -key-shares=5 -key-threshold=3 -format=json 2>&1)
# Stash the keys in script-local variables only.
mapfile -t UNSEAL_KEYS < <(jq -r '.unseal_keys_b64[]' <<<"$init_out")
ROOT_TOKEN=$(jq -r '.root_token' <<<"$init_out")

if [ "${#UNSEAL_KEYS[@]}" -ne 5 ] || [ -z "$ROOT_TOKEN" ]; then
    red "init didn't produce expected output. Raw:"
    red "$init_out"
    exit 1
fi

# 2. Print to stdout once. NEVER write to a file or a Secret.
yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " openbao-seal — INITIAL ROOT TOKEN + UNSEAL KEYS (Shamir 5/3)"
yellow ""
yellow "  Initial root token: $ROOT_TOKEN"
yellow ""
yellow "  Unseal key 1/5:     ${UNSEAL_KEYS[0]}"
yellow "  Unseal key 2/5:     ${UNSEAL_KEYS[1]}"
yellow "  Unseal key 3/5:     ${UNSEAL_KEYS[2]}"
yellow "  Unseal key 4/5:     ${UNSEAL_KEYS[3]}"
yellow "  Unseal key 5/5:     ${UNSEAL_KEYS[4]}"
yellow ""
yellow " Action required:"
yellow "   - Copy ALL 6 values into your offline password manager NOW."
yellow "   - You will need 3 of 5 unseal keys after every Docker Desktop"
yellow "     restart (run unseal-seal.sh and paste them)."
yellow "   - The root token below is used ONCE in this script and then"
yellow "     stays in your password manager as the break-glass credential."
yellow "═════════════════════════════════════════════════════════════════════"
yellow ""

# 3. Unseal with 3 of 5.
green "==> unsealing with 3 keys"
for i in 0 1 2; do
    bao operator unseal "${UNSEAL_KEYS[$i]}" >/dev/null
done
status=$(bao status -format=json 2>&1)
if ! echo "$status" | grep -q '"sealed": false'; then
    red "Unseal didn't take. status:"
    red "$status"
    exit 1
fi
green "    sealed=false"

# 4. Login as root + enable Transit + create unseal key.
# Pass BAO_TOKEN via env to avoid touching ~/.bao-token on the read-only
# pod filesystem (the chart's home volume is writable but we leave no
# token state behind).
green "==> enable transit + create unseal key"
authed() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" bao "$@"
}
authed secrets enable transit >/dev/null
authed write -f transit/keys/unseal type=aes256-gcm96 >/dev/null
green "    transit/keys/unseal created"

# 5. Write the unseal-policy.
green "==> writing unseal-policy"
kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c \
    "cat > /tmp/unseal-policy.hcl" <<'POLICY'
# Policy used by the main OpenBao's `seal "transit"` config to wrap and
# unwrap its data-encryption key. Permits ONLY encrypt/decrypt against
# the named key — no read of key material, no key rotation, no other
# capability.
path "transit/encrypt/unseal" {
  capabilities = ["update"]
}
path "transit/decrypt/unseal" {
  capabilities = ["update"]
}
POLICY
authed policy write unseal-policy /tmp/unseal-policy.hcl >/dev/null
green "    unseal-policy written"

# 6. Mint the periodic Transit unseal token for the main OpenBao.
#
# Phase 7d Item 3 (operator-backlog #4): switched from `-ttl=24h
# -renewable=true` to `-period=720h` (30 days). Rationale: a periodic
# token refreshes its TTL on every USE — and main OpenBao's transit-
# unseal call at boot counts as use. With a 30d period, normal local-
# edition usage (any cluster reboot more frequent than once-per-month)
# refreshes the token transparently. Cold-pause must exceed 30 days
# before the recovery script `rotate-transit-token.sh` is needed —
# vs. the prior 24h ceiling. ADR-0009 documents the trade-off.
green "==> minting Transit unseal token (period=720h, auto-renews on use)"
token_out=$(authed token create \
    -policy=unseal-policy \
    -period=720h \
    -format=json 2>&1)
TRANSIT_TOKEN=$(jq -r '.auth.client_token' <<<"$token_out")

if [ -z "$TRANSIT_TOKEN" ] || [ "$TRANSIT_TOKEN" = "null" ]; then
    red "Token mint failed. Output:"
    red "$token_out"
    exit 1
fi

yellow ""
yellow "═════════════════════════════════════════════════════════════════════"
yellow " openbao-seal Transit unseal token (for main OpenBao auto-unseal)"
yellow ""
yellow "  Transit token: $TRANSIT_TOKEN"
yellow ""
yellow " Action required:"
yellow "   - Copy this token into your offline password manager (with the"
yellow "     unseal keys + root token from above)."
yellow "   - Phase 5.3 needs this token in the main OpenBao's seal config."
yellow "   - The token is renewable; the main OpenBao auto-renews while up."
yellow "═════════════════════════════════════════════════════════════════════"
yellow ""

# 7. Clear the bao-CLI session.
kubectl exec -n "$NS" "$POD" -c openbao -- rm -f /home/openbao/.bao-token 2>/dev/null || true

green "Phase 5.2 init complete."
green "Next: capture all 7 secrets (5 unseal keys + root token + Transit token)"
green "      offline, then proceed to Phase 5.3 (deploy main OpenBao)."
