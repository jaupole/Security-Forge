#!/usr/bin/env bash
# 05b — Deploy and initialize the main OpenBao (3-replica Raft, Transit auto-unseal).
#
# *** RUN ONCE AFTER 05a. THE INIT STEP IS IRREVERSIBLE — RECOVERY KEYS APPEAR ONCE. ***
#
# Pre-conditions:
#   - 05a-openbao-bootstrap-seal.sh ran successfully
#   - Secret openbao-transit-token exists in openbao ns
#   - openbao-seal-0 is unsealed
#
# What this does:
#   1. Render seal HCL block (Transit token substituted from Secret) into
#      Secret `openbao-seal-block` (mounted into main pods, NOT in any ConfigMap)
#   2. Apply main NetworkPolicies + Postgres ingress allow + ingress + ServiceMonitor stub
#   3. Helm install openbao/openbao as release "openbao" (3-replica Raft)
#   4. Wait for openbao-{0,1,2} to be Running (sealed is OK)
#   5. Run `bao operator init -recovery-shares=5 -recovery-threshold=3`
#      DISPLAY 5 Recovery keys + initial root token ONCE
#   6. Verify all 3 replicas auto-unseal via Transit
#   7. Show Raft cluster membership

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/openbao"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

NS=openbao

# Pre-flight: ensure seal is ready + token Secret exists
if ! kubectl -n "$NS" get secret openbao-transit-token >/dev/null 2>&1; then
  echo "ERROR: Secret openbao/openbao-transit-token not found." >&2
  echo "       Run 05a-openbao-bootstrap-seal.sh first." >&2
  exit 1
fi

seal_status=$(kubectl exec -n "$NS" openbao-seal-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if ! echo "$seal_status" | grep -q '"sealed":[[:space:]]*false'; then
  echo "ERROR: openbao-seal is sealed. Unseal it first (use the Shamir keys from 05a)." >&2
  exit 1
fi

# 1. Render seal HCL block into Secret
echo ">>> Rendering openbao-seal-block Secret with Transit token"
TRANSIT_TOKEN=$(kubectl -n "$NS" get secret openbao-transit-token -o jsonpath='{.data.token}' | base64 -d)
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
kubectl -n "$NS" delete secret openbao-seal-block --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic openbao-seal-block \
  --from-literal=seal.hcl="$SEAL_HCL" >/dev/null
kubectl -n "$NS" label secret openbao-seal-block \
  app.kubernetes.io/name=openbao \
  secforge.platform/component=openbao \
  secforge.platform/purpose=seal-config-with-token \
  --overwrite >/dev/null
unset TRANSIT_TOKEN SEAL_HCL

# 2. NetworkPolicies + ingress
echo ">>> Applying main NetworkPolicies"
kubectl apply -f "$M/06-networkpolicies-main.yaml"

echo ">>> Applying public Ingress"
"$LIB/apply-manifest.sh" "$M/07-ingress.yaml"

# 3. Helm install main openbao (3-replica Raft)
"$LIB/install-helm.sh" \
  --release openbao \
  --namespace "$NS" \
  --repo-name openbao --repo-url https://openbao.github.io/openbao-helm \
  --chart openbao/openbao \
  --version 0.27.2 \
  --values "$PLATFORM_DIR/values/openbao.yaml"

# 4. Wait for openbao-{0,1,2}
echo ">>> Waiting for openbao-{0,1,2} to be Ready (sealed-but-Ready is OK pre-init)"
for i in 0 1 2; do
  for _ in {1..120}; do
    if kubectl -n "$NS" get pod "openbao-$i" >/dev/null 2>&1; then
      ready=$(kubectl -n "$NS" get pod "openbao-$i" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
      if [[ "$ready" == "true" ]]; then
        echo "    openbao-$i Ready"
        break
      fi
    fi
    sleep 5
  done
done

# Idempotency: skip init if already initialized
status=$(kubectl exec -n "$NS" openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if echo "$status" | grep -q '"initialized":[[:space:]]*true'; then
  echo
  echo "Main OpenBao is already initialized. Skipping init."
  for i in 0 1 2; do
    pod_status=$(kubectl exec -n "$NS" "openbao-$i" -c openbao -- env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
    sealed=$(echo "$pod_status" | jq -r '.sealed' 2>/dev/null || echo unknown)
    echo "    openbao-$i sealed=$sealed"
  done
  exit 0
fi

# 5. Init main with Recovery keys
cat <<'BANNER'

==========================================================================
 MAIN OPENBAO — INITIALIZATION (IRREVERSIBLE)

 About to run `bao operator init -recovery-shares=5 -recovery-threshold=3`.

 RECOVERY KEYS are NOT unseal keys — auto-unseal handles routine sealing
 via openbao-seal's Transit. Recovery keys are break-glass: used ONLY for
 `bao operator generate-root` (when you've lost the root token), or for
 rekey/rewrap operations. They will be displayed ONCE.

 The initial root token will also be displayed once. It is the only
 credential that can configure auth methods, secret engines, and policies
 until we set up OIDC auth (Phase 5 follow-up).

 Type "I UNDERSTAND" to proceed:
==========================================================================
BANNER
read -r ack
[[ "$ack" == "I UNDERSTAND" ]] || { echo "Aborted."; exit 1; }

echo ">>> bao operator init -recovery-shares=5 -recovery-threshold=3"
init_out=$(kubectl exec -n "$NS" openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
  bao operator init -recovery-shares=5 -recovery-threshold=3 -format=json 2>&1)

mapfile -t RECOVERY_KEYS < <(echo "$init_out" | jq -r '.recovery_keys_b64[]')
ROOT_TOKEN=$(echo "$init_out" | jq -r '.root_token')

if [[ ${#RECOVERY_KEYS[@]} -ne 5 || -z "$ROOT_TOKEN" ]]; then
  echo "ERROR: init produced unexpected output:" >&2
  echo "$init_out" >&2
  exit 1
fi

cat <<EOF

═══════════════════════════════════════════════════════════════════════════
 main OpenBao — INITIAL ROOT TOKEN + RECOVERY KEYS (5/3)

  Initial root token:  $ROOT_TOKEN

  Recovery key 1/5:    ${RECOVERY_KEYS[0]}
  Recovery key 2/5:    ${RECOVERY_KEYS[1]}
  Recovery key 3/5:    ${RECOVERY_KEYS[2]}
  Recovery key 4/5:    ${RECOVERY_KEYS[3]}
  Recovery key 5/5:    ${RECOVERY_KEYS[4]}

 STORE ALL 6 VALUES OFFLINE NOW (1Password / encrypted USB / paper).
═══════════════════════════════════════════════════════════════════════════

EOF
read -rp "Have you stored ALL 6 values offline? Type 'YES' to finish: " saved
[[ "$saved" == "YES" ]] || { echo "Continuing, but PLEASE save them!"; }

# 6. Verify auto-unseal
echo ">>> Waiting for all 3 replicas to auto-unseal via Transit"
for i in 0 1 2; do
  for _ in {1..60}; do
    if kubectl exec -n "$NS" "openbao-$i" -c openbao -- env BAO_SKIP_VERIFY=1 \
        bao status -format=json 2>&1 | grep -q '"sealed":[[:space:]]*false'; then
      echo "    openbao-$i sealed=false"
      break
    fi
    sleep 2
  done
done

# 7. Raft cluster membership
echo ">>> Raft cluster membership"
kubectl exec -n "$NS" openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" \
  bao operator raft list-peers 2>&1 | tail -20 || true

echo
echo "✓ Main OpenBao initialized + unsealed via Transit."
echo
echo "  Public ingress: https://bao.${DOMAIN}"
echo "  (Cert may take 1-2 min to issue via Let's Encrypt; check with:"
echo "    kubectl -n openbao get certificate openbao-public-tls)"
echo
echo "  Configuration of secret engines, auth methods, and policies"
echo "  is the next step but is NOT done by this script. Run the platform"
echo "  openbao-configure, openbao-jwt-auth, and openbao-oidc-auth"
echo "  components next (see platform/components/)."
