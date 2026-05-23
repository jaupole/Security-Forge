#!/usr/bin/env bash
# 05c — OpenBao configuration (Layer 1 — bedrock).
#
# Loads policies, enables KV-v2 + Transit secret engines, enables Kubernetes
# auth method. Skips JWT-SPIFFE auth (needs SPIRE OIDC discovery re-enabled),
# OIDC-Keycloak auth (needs platform realm), and the database engine (needs
# `app` namespace + secforge-app-db). Those come later when their pre-reqs
# are in place.
#
# Pre-condition: openbao-root-token-tmp Secret exists in openbao ns. Create with:
#   kubectl create secret generic openbao-root-token-tmp -n openbao \
#     --from-literal=token=<paste-from-1Password>
#
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

NS=openbao
POD=openbao-0

# Read root token from Secret (never echoes to terminal)
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: Secret openbao-root-token-tmp not found in openbao namespace.

Create it once (paste the main OpenBao initial root token from your 1Password):
  kubectl create secret generic openbao-root-token-tmp -n openbao \
    --from-literal=token=<paste-here>

Delete it after the configuration phase is complete (post-Layer 2):
  kubectl delete secret -n openbao openbao-root-token-tmp
EOF
  exit 1
fi
ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# ─── 1. Load policies ─────────────────────────────────────────────────────
POLICIES_DIR="$PLATFORM_DIR/manifests/openbao/policies"
echo ">>> Loading policies from $POLICIES_DIR (top level only; _deferred/ skipped)"
# NB: only top-level *.hcl files are loaded. The _deferred/ subdirectory
# holds policies that require pre-substitution (e.g., app-template.hcl needs
# the JWT auth accessor inlined before OpenBao will accept it). Those load
# in a later phase when their pre-reqs are met.
for f in "$POLICIES_DIR"/*.hcl; do
  name=$(basename "$f" .hcl)
  kubectl exec -i -n "$NS" "$POD" -c openbao -- /bin/sh -c "cat > /tmp/$name.hcl" < "$f"
  if bao bao policy write "$name" "/tmp/$name.hcl" >/dev/null 2>&1; then
    echo "    policy: $name"
  else
    echo "    policy: $name — FAILED" >&2
    bao bao policy write "$name" "/tmp/$name.hcl" 2>&1 | head -5 >&2
    exit 1
  fi
done

# ─── 2. KV-v2 secrets engine ──────────────────────────────────────────────
echo ">>> Enabling kv-v2 at secret/"
if bao bao secrets list -format=json 2>/dev/null | grep -q '"secret/":'; then
  echo "    already enabled"
else
  bao bao secrets enable -version=2 -path=secret kv 2>&1 | tail -1
fi

# ─── 3. Transit secrets engine + pii-encryption key ───────────────────────
echo ">>> Enabling transit/"
if bao bao secrets list -format=json 2>/dev/null | grep -q '"transit/":'; then
  echo "    already enabled"
else
  bao bao secrets enable transit 2>&1 | tail -1
fi

echo ">>> transit/keys/pii-encryption (aes256-gcm96)"
bao bao read transit/keys/pii-encryption >/dev/null 2>&1 \
  && echo "    already exists" \
  || bao bao write -f transit/keys/pii-encryption type=aes256-gcm96 2>&1 | tail -1

# audit-signing (ed25519, non-deletable) — signs audit-anchor checkpoints
# emitted by member-hub-audit-signer and future per-app audit signers.
# Bound via the `audit-signer` policy + per-app k8s-auth roles in 05j.
# deletion_allowed=false because losing this key invalidates the entire
# anchor chain back to genesis — accidental delete is unrecoverable.
echo ">>> transit/keys/audit-signing (ed25519, deletion_allowed=false)"
if bao bao read transit/keys/audit-signing >/dev/null 2>&1; then
  echo "    already exists"
else
  bao bao write -f transit/keys/audit-signing type=ed25519 2>&1 | tail -1
  bao bao write transit/keys/audit-signing/config deletion_allowed=false 2>&1 | tail -1
fi

# ─── 4. Kubernetes auth method ─────────────────────────────────────────────
echo ">>> Enabling kubernetes auth"
if bao bao auth list -format=json 2>/dev/null | grep -q '"kubernetes/":'; then
  echo "    already enabled"
else
  bao bao auth enable kubernetes 2>&1 | tail -1
fi

echo ">>> Configuring kubernetes auth (kubernetes_host + CA from in-pod files)"
bao bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_local_ca_jwt="false" 2>&1 | tail -1

# ─── 5. admin-break-glass role ────────────────────────────────────────────
# Per docs/03-runbooks/openbao-recovery.md § "Kubernetes auth break-glass":
# anyone with `kubectl exec` into openbao ns can mint a 1h admin token via
# the openbao SA. Closes operator-backlog #34 (the runbook claimed this role
# existed; it never actually did until 2026-05-19).
echo ">>> Creating auth/kubernetes/role/admin-break-glass (admin policy, 1h ttl)"
bao bao write auth/kubernetes/role/admin-break-glass \
  bound_service_account_names=openbao \
  bound_service_account_namespaces=openbao \
  token_policies=admin \
  token_ttl=1h \
  token_max_ttl=1h 2>&1 | tail -1

# Clear root token from process memory (the Secret is the canonical source)
unset ROOT_TOKEN

cat <<EOF

✓ OpenBao Layer 1 configuration complete.

  Loaded $(ls "$POLICIES_DIR"/*.hcl | wc -l) policies.
  Enabled engines: kv-v2 (at secret/), transit (with pii-encryption + audit-signing keys).
  Enabled auth methods: kubernetes.
  Created roles: admin-break-glass (k8s SA openbao/openbao → admin policy, 1h ttl).

  Next: bash $SCRIPT_DIR/05d-vso-install.sh
  (App-level k8s-auth roles for control, member-hub, ... are in 05j.)
EOF
