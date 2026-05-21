#!/usr/bin/env bash
# 12c — Kyverno image-verification registry credential.
#
# Gives the Kyverno admission controller a read-only GHCR credential so the
# verify-image-signature ClusterPolicy can pull cosign signatures for the
# PRIVATE ghcr.io/jaupole/* (+ secforge/*) packages. Without it, Kyverno
# verifies those images anonymously, ghcr.io answers 401, and the
# verify-secforge rule never actually verifies anything.
#
# This is the registry-auth half of the fix. The network half — egress
# from the admission controller to ghcr.io + sigstore — is the
# NetworkPolicy in manifests/kyverno/06-egress-image-verification.yaml,
# applied with the rest of the namespace's manifests.
#
# Order of operations (idempotent):
#   1. Apply the VSO binding (SA kyverno-vso + VaultAuth + VaultStaticSecret).
#   2. Create OpenBao K8s auth role kyverno-vso (policy: vso — the shared
#      vso.hcl already grants read on secret/data/apps/control/+, which
#      covers the apps/control/ghcr-pull path).
#   3. Wait for VSO to render the ghcr-pull-secret Secret.
#
# Pre-conditions:
#   - 12-kyverno.sh complete (kyverno namespace + controllers).
#   - 05c / 05e complete (OpenBao kubernetes auth + vso policy loaded).
#   - openbao-root-token-tmp Secret staged in the openbao namespace.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

NS=kyverno
NS_BAO=openbao
POD_BAO=openbao-0
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found in $NS_BAO."
  red "       Day-2 runs without it: mint an admin token via the"
  red "       admin-break-glass role (docs/03-runbooks/openbao-recovery.md)"
  red "       and write auth/kubernetes/role/kyverno-vso by hand."
  exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. VSO binding (SA + VaultAuth + VaultStaticSecret)
green "==> apply kyverno VSO binding"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/kyverno/03-vso-binding.yaml"

# 2. OpenBao K8s auth role. policy=vso — vso.hcl (loaded by 05c) already
#    grants read on secret/data/apps/control/+ (the ghcr-pull path).
green "==> write OpenBao K8s auth role: kyverno-vso"
bao bao write auth/kubernetes/role/kyverno-vso \
  bound_service_account_names="kyverno-vso" \
  bound_service_account_namespaces="kyverno" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 3. Wait for VSO render
green "==> waiting for VSO to render ghcr-pull-secret (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret ghcr-pull-secret >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render ghcr-pull-secret within 60s"; exit 1
  fi
  sleep 5
done

echo
green "✓ Kyverno image-verification credential ready."
echo "  verify-image-signature can now pull signatures for the private"
echo "  ghcr.io/jaupole/* + secforge/* packages."
