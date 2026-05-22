#!/usr/bin/env bash
# 00b — cert-manager + Cloudflare-backed Let's Encrypt + wildcard cert.
#
# What this does (idempotent):
#   1. Apply cert-manager namespace.
#   2. Helm install/upgrade cert-manager (jetstack/cert-manager v1.20.x).
#   3. Migrate Cloudflare API token from existing static K8s Secret
#      (`cloudflare-api-token` in cert-manager ns) into OpenBao at
#      `secret/data/platform/cert-manager/cloudflare`. Skip if either
#      the OpenBao value already exists (re-run safety) or there's no
#      static Secret to migrate from (fresh deploy: operator must `bao
#      kv put` the token first — see fresh-deploy bootstrap below).
#   4. Re-load vso.hcl policy (already includes the cloudflare path).
#   5. Apply VSO binding (renders K8s Secret `cloudflare-api-token-vso`).
#   6. Create OpenBao K8s auth role `cert-manager-vso`.
#   7. Wait for VSO to render the Secret.
#   8. Apply ClusterIssuers (letsencrypt-staging + letsencrypt-prod)
#      pointing at the VSO-rendered Secret.
#   9. Apply wildcard Certificate CR.
#  10. Delete the legacy static `cloudflare-api-token` Secret (after
#      ClusterIssuer cutover; safe because the new VSO-rendered secret
#      is the live one).
#
# Pre-conditions:
#   - openbao-root-token-tmp Secret in openbao ns (for OpenBao writes).
#   - For first deploy without the legacy Secret: operator must paste the
#     CF token into OpenBao manually:
#       bao kv put secret/platform/cert-manager/cloudflare token=<paste>
#
# Reproducibility note: this script encodes the cert-manager setup that
# was previously implicit (Phase B of the original migration playbook).
# Re-running on a fresh cluster with a pre-staged CF token in OpenBao
# reproduces the entire cert-manager + Let's Encrypt + wildcard state.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${CERT_MANAGER_CHART_VER:-v1.20.2}"
NS=cert-manager
NS_BAO=openbao
POD_BAO=openbao-0

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/cert-manager/01-namespace.yaml"

# 2. Helm install
"$LIB/install-helm.sh" \
  --release cert-manager --namespace "$NS" \
  --repo-name jetstack --repo-url https://charts.jetstack.io \
  --chart jetstack/cert-manager --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/cert-manager.yaml"

# 3. CF token migration into OpenBao (if not already there)
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  yellow "==> openbao-root-token-tmp Secret missing — skipping CF token migration"
  yellow "    Re-run after pasting the root token to wire VSO."
  yellow "    (cert-manager itself is up; existing static Secret continues to work.)"
  exit 0
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

green "==> check OpenBao for existing CF token"
EXISTING=$(bao bao kv get -field=token secret/platform/cert-manager/cloudflare 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  yellow "    found existing OpenBao value — skipping migration"
elif kubectl -n "$NS" get secret cloudflare-api-token >/dev/null 2>&1; then
  green "==> migrate CF token from legacy Secret cert-manager/cloudflare-api-token → OpenBao"
  CF_TOKEN=$(kubectl -n "$NS" get secret cloudflare-api-token -o jsonpath='{.data.api-token}' | base64 -d)
  if [ -z "$CF_TOKEN" ]; then
    red "    legacy Secret exists but api-token field is empty — abort"
    exit 1
  fi
  bao bao kv put secret/platform/cert-manager/cloudflare token="$CF_TOKEN" >/dev/null
  unset CF_TOKEN
  green "    migrated"
else
  red "    no CF token available (no OpenBao value, no legacy Secret)."
  red "    Operator must paste the CF token into OpenBao manually:"
  red "      bao kv put secret/platform/cert-manager/cloudflare token=<paste>"
  exit 1
fi

# 4. Re-load vso policy
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 5. Apply VSO binding
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/cert-manager/02-cloudflare-vso-binding.yaml"

# 6. K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: cert-manager-vso"
bao bao write auth/kubernetes/role/cert-manager-vso \
  bound_service_account_names="cert-manager-vso" \
  bound_service_account_namespaces="cert-manager" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 7. Wait for VSO render
green "==> waiting for VSO to render cloudflare-api-token-vso (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret cloudflare-api-token-vso >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render cloudflare-api-token-vso within 60s"; exit 1
  fi
  sleep 5
done

# 8. Apply ClusterIssuers (now pointing at VSO-rendered Secret)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/cert-manager/03-cluster-issuers.yaml"

# 9. Wildcard cert (issued by letsencrypt-prod ClusterIssuer)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/cert-manager/04-wildcard-cert.yaml"

# 10. Delete legacy static Secret AFTER giving cert-manager a moment to
# pick up the new ClusterIssuer reference.
sleep 10
if kubectl -n "$NS" get secret cloudflare-api-token >/dev/null 2>&1; then
  green "==> delete legacy static Secret cloudflare-api-token (replaced by VSO-rendered)"
  kubectl -n "$NS" delete secret cloudflare-api-token
fi

echo
green "✓ cert-manager + Cloudflare DNS-01 + wildcard cert wired."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods,clusterissuer,certificate"
echo "  kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}'"
echo "  kubectl get certificate secforge-wildcard -n cert-manager"
