#!/usr/bin/env bash
# 05d — Vault Secrets Operator (VSO) install.
#
# Installs the HashiCorp VSO Helm chart in vault-secrets-operator namespace.
# Wires VaultConnection + VaultAuth pointing at our OpenBao with our internal
# CA bundle. Adds NetworkPolicies (default-deny ingress + targeted egress).
#
# Pre-conditions:
#   - 05c (kubernetes auth method enabled in OpenBao) ran
#   - openbao-ca Secret exists in openbao ns (from 03-ca.yaml CA Issuer)
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/vault-secrets-operator"

NS=vault-secrets-operator

# 1. Namespace
echo ">>> Creating $NS namespace"
kubectl apply -f "$M/01-namespace.yaml"

# 2. Copy openbao internal CA into VSO namespace as openbao-ca-bundle
# (VSO's VaultConnection points at this for TLS verification of openbao endpoints)
echo ">>> Copying openbao-ca into $NS as openbao-ca-bundle"
CA_PEM=$(kubectl -n openbao get secret openbao-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [[ -z "$CA_PEM" ]]; then
  echo "ERROR: could not read openbao-ca cert from openbao ns" >&2
  exit 1
fi
kubectl -n "$NS" create secret generic openbao-ca-bundle \
  --from-literal=ca.crt="$CA_PEM" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" label secret openbao-ca-bundle \
  secforge.platform/component=vault-secrets-operator --overwrite >/dev/null

# 3. Helm install VSO
"$LIB/install-helm.sh" \
  --release vault-secrets-operator \
  --namespace "$NS" \
  --repo-name hashicorp --repo-url https://helm.releases.hashicorp.com \
  --chart hashicorp/vault-secrets-operator \
  --values "$PLATFORM_DIR/values/vault-secrets-operator.yaml"

echo ">>> Waiting for VSO controller Ready"
kubectl -n "$NS" rollout status deployment/vault-secrets-operator-controller-manager --timeout=300s

# 4. NetworkPolicies (default-deny ingress in VSO ns + egress to openbao + ingress allow on openbao ns)
echo ">>> Applying NetworkPolicies"
kubectl apply -f "$M/04-networkpolicies.yaml"

# 5. VaultConnection + VaultAuth (CRDs from VSO chart)
# Both reference cluster-internal hostnames + the openbao role we'll create in 05e.
echo ">>> Applying VaultConnection + VaultAuth"
kubectl apply -f "$M/02-vault-connection.yaml"
kubectl apply -f "$M/03-vault-auth.yaml"

cat <<EOF

✓ VSO installed.

  Helm release:  vault-secrets-operator
  Controller:    Deployment vault-secrets-operator-controller-manager
  Connection:    https://openbao.openbao.svc.cluster.local:8200
  Auth method:   kubernetes (mount=kubernetes, role=vault-secrets-operator)

  VSO will fail to authenticate until the role exists in OpenBao.
  Next: bash $SCRIPT_DIR/05e-vso-configure.sh
EOF
