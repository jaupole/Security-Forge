#!/usr/bin/env bash
# Phase 6.10b Step 2 — install Vault Secrets Operator (VSO).
#
# Idempotent. Safe to re-run.
#
# Order:
#   1. Ensure namespace exists (declared in infrastructure/namespaces/namespaces.yaml).
#   2. Copy mkcert CA bundle into vault-secrets-operator ns as `openbao-ca-bundle`.
#   3. helm repo add hashicorp / helm upgrade --install vault-secrets-operator.
#   4. Wait for the controller Deployment Ready.
#   5. Apply NetworkPolicies (own ns + openbao ns ingress allow).
#   6. Apply VaultConnection + VaultAuth CRDs.
#   7. Tail the controller log briefly to surface auth failures early.
#
# Step 6 (VaultStaticSecret resources for spicedb-config-vso) is NOT done
# here — that's Step 3 of the 6.10b plan. This script gets us to "VSO is
# installed and authed; nothing rendered yet."

set -euo pipefail

NS=vault-secrets-operator
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}
require_cmd kubectl
require_cmd helm

# 1. Namespace.
green "==> ensuring namespace $NS exists"
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    yellow "    namespace $NS not found — applying namespaces.yaml"
    kubectl apply -f "$REPO_ROOT/infrastructure/namespaces/namespaces.yaml"
fi

# 2. CA bundle.
green "==> copying mkcert CA into $NS as openbao-ca-bundle"
CA_PEM=$(kubectl get secret -n cert-manager mkcert-ca-key-pair \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [ -z "$CA_PEM" ]; then
    red "could not read mkcert-ca-key-pair from cert-manager namespace"
    exit 1
fi
kubectl create secret generic openbao-ca-bundle \
    -n "$NS" \
    --from-literal=ca.crt="$CA_PEM" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" label secret openbao-ca-bundle \
    secforge.platform/component=vault-secrets-operator \
    --overwrite >/dev/null

# 3. Helm install.
green "==> ensuring hashicorp helm repo"
if ! helm repo list 2>/dev/null | grep -q '^hashicorp[[:space:]]'; then
    helm repo add hashicorp https://helm.releases.hashicorp.com
fi
helm repo update hashicorp >/dev/null

green "==> helm upgrade --install vault-secrets-operator"
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
    --namespace "$NS" \
    --values "$HERE/01-helm-values.yaml" \
    --wait --timeout=180s

# 4. Wait for controller Ready (helm --wait should cover this; double-check).
green "==> waiting for controller Deployment Ready"
kubectl -n "$NS" rollout status deployment/vault-secrets-operator-controller-manager --timeout=180s

# 5. NetworkPolicies (own ns + openbao ingress allow).
green "==> applying NetworkPolicies"
kubectl apply -f "$HERE/04-networkpolicies.yaml"

# 6. VaultConnection + VaultAuth.
#    Note: configure-openbao-role.sh must run BEFORE these CRDs are useful,
#    since VSO will fail to authenticate until the OpenBao role exists.
#    But the CRDs themselves are inert until referenced by a
#    VaultStaticSecret, so applying them now is safe.
green "==> applying VaultConnection + VaultAuth"
kubectl apply -f "$HERE/02-vault-connection.yaml"
kubectl apply -f "$HERE/03-vault-auth.yaml"

green ""
green "VSO installed. Next:"
green "  1. BAO_TOKEN=<admin> bash $HERE/configure-openbao-role.sh"
green "     (creates the K8s auth role + writes the vso policy)"
green "  2. bash $HERE/verify.sh"
green "     (confirms VSO can authenticate to OpenBao)"
green ""
green "Step 3 of the 6.10b plan (VaultStaticSecret for spicedb-config-vso)"
green "is the next thing to do. See"
green "  docs/05-claude-code-prompts/phase-06.10b-vso-and-secret-cleanup.md"
green ""
