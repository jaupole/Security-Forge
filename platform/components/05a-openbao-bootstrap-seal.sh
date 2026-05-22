#!/usr/bin/env bash
# 05a — Deploy and initialize openbao-seal.
#
# *** RUN ONCE. THE INIT STEP IS IRREVERSIBLE — SHAMIR KEYS APPEAR ONCE. ***
#
# What this does:
#   1. Apply namespace + ServiceAccounts + CA + leaf Certificates + seal NetworkPolicies
#   2. Helm install openbao/openbao as release "openbao-seal"
#   3. Wait for openbao-seal-0 pod Ready (sealed is OK; readiness probe accepts sealedcode=204)
#   4. If not initialized: run `bao operator init -key-shares=5 -key-threshold=3`
#      DISPLAY 5 Shamir unseal keys + initial root token ONCE.
#      Wait for operator confirmation that they are saved offline.
#   5. Unseal with 3 of 5 keys
#   6. Enable Transit secrets engine, create the `unseal` aes256-gcm96 key
#   7. Write `unseal-policy` (only encrypt/decrypt against transit/keys/unseal)
#   8. Mint a periodic Transit token (period=720h, auto-renews on use) for the
#      main OpenBao to consume during auto-unseal
#   9. Store the Transit token in Secret `openbao-transit-token` (consumed by 05b)
#  10. DISPLAY the Transit token ONCE for offline backup as well

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/openbao"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

NS=openbao

# 1. Namespace + ServiceAccounts + CA + Certificates + NetworkPolicies (seal)
echo ">>> Applying namespace, SA, CA, certs, network policies"
kubectl apply -f "$M/01-namespace.yaml"
kubectl apply -f "$M/02-serviceaccounts.yaml"
kubectl apply -f "$M/03-ca.yaml"

# Wait for the CA Issuer to be ready (the root CA cert must materialize first)
echo ">>> Waiting for openbao-ca-issuer to be Ready"
kubectl wait --for=condition=Ready certificate/openbao-ca -n "$NS" --timeout=120s
kubectl wait --for=condition=Ready issuer/openbao-ca-issuer -n "$NS" --timeout=60s

kubectl apply -f "$M/04-certificates.yaml"
kubectl apply -f "$M/05-networkpolicies-seal.yaml"

# 2. Helm install openbao-seal
"$LIB/install-helm.sh" \
  --release openbao-seal \
  --namespace "$NS" \
  --repo-name openbao --repo-url https://openbao.github.io/openbao-helm \
  --chart openbao/openbao \
  --version 0.27.2 \
  --values "$PLATFORM_DIR/values/openbao-seal.yaml"

# 3. Wait for pod (sealed is OK). StatefulSet uses OnDelete update strategy
# so `kubectl rollout status` doesn't work — poll pod readiness directly.
echo ">>> Waiting for openbao-seal-0 to be Ready (sealed is OK)"
for _ in {1..150}; do
  if kubectl -n "$NS" get pod openbao-seal-0 >/dev/null 2>&1; then
    ready=$(kubectl -n "$NS" get pod openbao-seal-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
    if [[ "$ready" == "true" ]]; then
      echo "    openbao-seal-0 Ready"
      break
    fi
  fi
  sleep 2
done

if ! kubectl -n "$NS" get pod openbao-seal-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
  echo "ERROR: openbao-seal-0 did not become Ready within 5 minutes" >&2
  kubectl -n "$NS" describe pod openbao-seal-0 | tail -30 >&2
  exit 1
fi

# Idempotency: skip init if already initialized
status=$(kubectl exec -n "$NS" openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if echo "$status" | grep -q '"initialized":[[:space:]]*true'; then
  echo
  echo "openbao-seal is already initialized."
  if echo "$status" | grep -q '"sealed":[[:space:]]*true'; then
    echo "But it is currently SEALED. Run unseal-seal helper to unseal it:"
    echo "  bash $SCRIPT_DIR/unseal-seal.sh"
  else
    echo "Status: unsealed and ready. Proceed to 05b."
  fi
  exit 0
fi

# 4. Init
cat <<'BANNER'

==========================================================================
 OPENBAO-SEAL — INITIALIZATION (IRREVERSIBLE)

 About to run `bao operator init -key-shares=5 -key-threshold=3`. This
 will display 5 Shamir unseal keys + 1 initial root token EXACTLY ONCE.

 You must capture all 6 values to your offline password manager BEFORE
 this script proceeds. If you lose them, this OpenBao becomes a black
 box — no admin access, no way to unseal after a restart.

 You will need 3 of 5 unseal keys after every restart of this pod
 (e.g., a host reboot — the seal pod re-seals on every cold start).

 Type "I UNDERSTAND" to proceed:
==========================================================================
BANNER
read -r ack
[[ "$ack" == "I UNDERSTAND" ]] || { echo "Aborted."; exit 1; }

bao() {
  kubectl exec -n "$NS" openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao "$@"
}

echo ">>> bao operator init -key-shares=5 -key-threshold=3"
init_out=$(bao operator init -key-shares=5 -key-threshold=3 -format=json 2>&1)

mapfile -t UNSEAL_KEYS < <(echo "$init_out" | jq -r '.unseal_keys_b64[]')
ROOT_TOKEN=$(echo "$init_out" | jq -r '.root_token')

if [[ ${#UNSEAL_KEYS[@]} -ne 5 || -z "$ROOT_TOKEN" ]]; then
  echo "ERROR: init produced unexpected output:" >&2
  echo "$init_out" >&2
  exit 1
fi

cat <<EOF

═══════════════════════════════════════════════════════════════════════════
 openbao-seal — INITIAL ROOT TOKEN + UNSEAL KEYS (Shamir 5/3)

  Initial root token:  $ROOT_TOKEN

  Unseal key 1/5:      ${UNSEAL_KEYS[0]}
  Unseal key 2/5:      ${UNSEAL_KEYS[1]}
  Unseal key 3/5:      ${UNSEAL_KEYS[2]}
  Unseal key 4/5:      ${UNSEAL_KEYS[3]}
  Unseal key 5/5:      ${UNSEAL_KEYS[4]}

 STORE ALL 6 VALUES OFFLINE NOW (1Password / encrypted USB / paper).
═══════════════════════════════════════════════════════════════════════════

EOF
read -rp "Have you stored ALL 6 values offline? Type 'YES' to continue: " saved
[[ "$saved" == "YES" ]] || { echo "Aborted before unsealing."; exit 1; }

# 5. Unseal with 3 of 5
echo ">>> Unsealing seal OpenBao with 3 of 5 keys"
for i in 0 1 2; do
  bao operator unseal "${UNSEAL_KEYS[$i]}" >/dev/null
done

if ! bao status -format=json | grep -q '"sealed":[[:space:]]*false'; then
  echo "ERROR: unseal did not take" >&2
  bao status >&2
  exit 1
fi
echo "    sealed=false ✓"

# 6. Enable Transit + create unseal key
echo ">>> Enable transit secrets engine + create transit/keys/unseal"
authed() {
  kubectl exec -n "$NS" openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" bao "$@"
}
authed secrets enable transit >/dev/null
authed write -f transit/keys/unseal type=aes256-gcm96 >/dev/null

# 7. Write unseal-policy
echo ">>> Writing unseal-policy"
kubectl exec -i -n "$NS" openbao-seal-0 -c openbao -- /bin/sh -c \
  "cat > /tmp/unseal-policy.hcl" <<'POLICY'
path "transit/encrypt/unseal" {
  capabilities = ["update"]
}
path "transit/decrypt/unseal" {
  capabilities = ["update"]
}
POLICY
authed policy write unseal-policy /tmp/unseal-policy.hcl >/dev/null

# 8. Mint periodic Transit token (period=720h, auto-renews on use)
echo ">>> Minting Transit unseal token (period=720h)"
token_out=$(authed token create -policy=unseal-policy -period=720h -format=json 2>&1)
TRANSIT_TOKEN=$(echo "$token_out" | jq -r '.auth.client_token')

if [[ -z "$TRANSIT_TOKEN" || "$TRANSIT_TOKEN" == "null" ]]; then
  echo "ERROR: token mint failed" >&2
  echo "$token_out" >&2
  exit 1
fi

# 9. Store Transit token in Secret for 05b to consume
kubectl -n "$NS" delete secret openbao-transit-token --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic openbao-transit-token \
  --from-literal=token="$TRANSIT_TOKEN" >/dev/null
kubectl -n "$NS" label secret openbao-transit-token \
  app.kubernetes.io/name=openbao \
  secforge.platform/component=openbao \
  secforge.platform/purpose=seal-transit-token \
  --overwrite >/dev/null

cat <<EOF

═══════════════════════════════════════════════════════════════════════════
 openbao-seal Transit unseal token (also stored in Secret openbao-transit-token)

  Transit token:  $TRANSIT_TOKEN

 STORE OFFLINE alongside the 5 unseal keys + root token from above.
 The token is renewable; the main OpenBao auto-renews while up.
═══════════════════════════════════════════════════════════════════════════

EOF
read -rp "Have you stored the Transit token offline? Type 'YES' to finish: " saved2
[[ "$saved2" == "YES" ]] || { echo "Continuing anyway, but please save it!"; }

# Cleanup CLI session
kubectl exec -n "$NS" openbao-seal-0 -c openbao -- rm -f /home/openbao/.bao-token 2>/dev/null || true

echo
echo "✓ openbao-seal initialized + unsealed + Transit configured."
echo "  Next: bash 05b-openbao-bootstrap-main.sh"
