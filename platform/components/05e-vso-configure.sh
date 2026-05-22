#!/usr/bin/env bash
# 05e — Configure OpenBao K8s auth role for VSO operator-self.
#
# Writes the `vault-secrets-operator` role in OpenBao that binds the VSO
# controller's ServiceAccount to the `vso` policy (already loaded by 05c).
#
# Per-namespace consumer roles (spicedb-vso, grafana-vso, etc.) are NOT
# created here — those get added when their consuming components deploy.
# The local edition's configure-openbao-role.sh creates 7 roles at once;
# for production we add them as we go.
#
# Pre-conditions:
#   - 05c ran (vso policy loaded, kubernetes auth enabled)
#   - 05d ran (VSO controller deployed, ServiceAccount exists)
#   - openbao-root-token-tmp Secret in openbao ns
#
# Idempotent.

set -euo pipefail

NS=openbao
POD=openbao-0

# Pre-flight: VSO ServiceAccount must exist
if ! kubectl -n vault-secrets-operator get sa vault-secrets-operator-controller-manager >/dev/null 2>&1; then
  echo "ERROR: ServiceAccount vault-secrets-operator-controller-manager not found." >&2
  echo "       Run 05d-vso-install.sh first." >&2
  exit 1
fi

# Pre-flight: root token Secret
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  echo "ERROR: openbao-root-token-tmp Secret not found. See 05c for setup." >&2
  exit 1
fi
ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# Audience must match what VSO presents in its projected SA token.
# Hardcoded in 03-vault-auth.yaml's audiences list — both must agree.
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"

echo ">>> Writing K8s auth role: vault-secrets-operator (operator-self)"
bao bao write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names="vault-secrets-operator-controller-manager" \
  bound_service_account_namespaces="vault-secrets-operator" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

cat <<'EOF'

✓ VSO operator-self auth role created.

Verify VSO can authenticate to OpenBao:
  kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=50 | grep -iE 'auth|login|error' | tail -20

Look for "auth.success" or similar — first sync attempt should land within 60s.

After verifying, the next deployment phase wires per-namespace consumers:
  - spicedb-vso role (when migrating spicedb-config to VSO-rendered)
  - app-namespace consumer (when apps are deployed)
  - observability consumers (when Phase 7 deploys)
EOF
