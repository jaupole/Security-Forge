#!/usr/bin/env bash
# 05k — App-level OpenBao JWT-SPIFFE auth roles + token bound_cidrs.
#
# Creates idempotent jwt-auth roles for the SPIFFE-bound app identities
# (control, member-hub) that perform Transit encrypt/decrypt. Mirrors
# 05j (k8s-auth roles for VSO) but for the JWT side.
#
# Closes the gap surfaced 2026-05-27: the live cluster had these JWT
# roles in memory (added during initial bootstrap) but they were not
# codified in any script. A cluster rebuild would have left every app
# unable to authenticate to Transit until an operator re-created them
# by hand.
#
# Also lands `token_bound_cidrs` on each role — a defence-in-depth
# hardening against captured-token replay from outside the cluster.
# If an attacker exfiltrates a Control or Member Hub OpenBao token,
# the token is useless from any source IP outside the k3s pod CIDR.
# The auth side (`bound_cidrs`) is set identically; an attacker who
# captures the JWT-SVID file would also need to authenticate from a
# pod-network source IP, which they can't reach from outside the
# cluster.
#
# Pre-condition: 05f ran (JWT auth method enabled + configured) and
# the per-app SPIRE registration entries exist.
#
# Idempotent — `bao write auth/jwt/role/...` upserts.

set -euo pipefail

NS=openbao
POD=openbao-0

# Read root token from Secret (same pattern as 05c / 05j).
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: Secret openbao-root-token-tmp not found in openbao namespace.

Re-create with the main OpenBao root token from 1Password (or mint a
1h admin token via the admin-break-glass role and write it):
  kubectl create secret generic openbao-root-token-tmp -n openbao \
    --from-literal=token=<paste-here>

Delete it after this script completes:
  kubectl delete secret -n openbao openbao-root-token-tmp
EOF
  exit 1
fi
ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# Cluster pod CIDR — the source IP of every in-cluster auth attempt
# and every in-cluster token use. Derived from `kubectl get nodes
# -o jsonpath='{.items[*].spec.podCIDR}'`; on k3s this is the
# flannel-assigned 10.42.x.x range. The token + auth bound_cidrs
# entries below restrict to it.
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"

# Trust domain — used to compose the bound_subject. Override via env
# if the cluster's SPIRE config diverges from the default.
TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-secforge.platform}"

# Format: role | ns | sa | token_policies | token_ttl | token_max_ttl
JWT_ROLES=(
  "control|control|control|control|900|3600"
  "member-hub|member-hub|member-hub|member-hub|900|3600"
)

echo ">>> Creating app-level jwt-auth roles (pod CIDR: $POD_CIDR)"
for row in "${JWT_ROLES[@]}"; do
  IFS='|' read -r ROLE SA_NS SA_NAME POL TTL MAX_TTL <<< "$row"
  BOUND_SUB="spiffe://${TRUST_DOMAIN}/ns/${SA_NS}/sa/${SA_NAME}"
  echo "    $ROLE  (subject: $BOUND_SUB → policy: $POL, ttl=${TTL}s max=${MAX_TTL}s)"
  bao bao write "auth/jwt/role/$ROLE" \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="openbao" \
    bound_subject="$BOUND_SUB" \
    token_policies="$POL" \
    token_ttl="$TTL" \
    token_max_ttl="$MAX_TTL" \
    token_metadata="app=$ROLE" \
    bound_cidrs="$POD_CIDR" \
    token_bound_cidrs="$POD_CIDR" >/dev/null
done

unset ROOT_TOKEN

cat <<EOF

✓ App-level JWT-SPIFFE auth roles applied.

  Roles upserted: ${#JWT_ROLES[@]}.
  bound_cidrs + token_bound_cidrs scoped to $POD_CIDR — a captured
  token is unusable from outside the cluster pod network.

  Add new SPIFFE-bound apps by appending a row to JWT_ROLES.

  Delete the temp Secret when this returns 0:
    kubectl delete secret -n openbao openbao-root-token-tmp
EOF
