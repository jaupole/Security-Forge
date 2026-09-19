#!/usr/bin/env bash
# 07e — kube-prometheus-stack (Prometheus + Alertmanager + node-exporter
# + kube-state-metrics + Grafana with OIDC-federated login).
#
# Order of operations (idempotent):
#   1. Read Grafana client_secret from K8s Secret keycloak/keycloak-grafana-client-secret
#      (created by 07d).
#   2. Stage at OpenBao secret/data/grafana/oidc.
#   3. Re-load vso policy (already includes grafana/oidc path).
#   4. Apply VSO binding in observability ns.
#   5. Create OpenBao K8s auth role grafana-vso.
#   6. Wait for VSO to render grafana-oidc-client-secret K8s Secret.
#   7. Helm install kube-prometheus-stack.
#   8. Apply Grafana Ingress + Certificate + NetworkPolicy.
#
# Pre-conditions:
#   - 07d-keycloak-grafana-client.sh has run (Secret keycloak/keycloak-grafana-client-secret).
#   - openbao-root-token-tmp Secret in openbao ns.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${KPS_CHART_VER:-84.5.0}"
NS=observability
NS_BAO=openbao
NS_KC=keycloak
POD_BAO=openbao-0

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found in $NS_BAO."
  red "       Re-create with the OpenBao initial root token from 1Password."
  exit 1
fi
if ! kubectl -n "$NS_KC" get secret keycloak-grafana-client-secret >/dev/null 2>&1; then
  red "ERROR: Secret keycloak-grafana-client-secret missing in $NS_KC."
  red "       Run 07d-keycloak-grafana-client.sh first."
  exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
GRAFANA_OIDC_SECRET=$(kubectl -n "$NS_KC" get secret keycloak-grafana-client-secret -o jsonpath='{.data.client_secret}' | base64 -d)

bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1+2. Stage at OpenBao
green "==> stage Grafana OIDC client_secret at secret/grafana/oidc"
bao bao kv put secret/grafana/oidc client_secret="$GRAFANA_OIDC_SECRET" >/dev/null
unset GRAFANA_OIDC_SECRET

# 3. Re-load vso policy (already has grafana/oidc path; idempotent)
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 4. Apply VSO binding
green "==> apply VSO binding for Grafana OIDC secret"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/05-grafana-vso-binding.yaml"

# 5. Create OpenBao K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: grafana-vso"
bao bao write auth/kubernetes/role/grafana-vso \
  bound_service_account_names="grafana-vso" \
  bound_service_account_namespaces="observability" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 6. Wait for VSO render
green "==> waiting for VSO to render grafana-oidc-client-secret (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret grafana-oidc-client-secret >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"
    break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render grafana-oidc-client-secret within 60s"
    red "  - confirm OpenBao has secret/data/grafana/oidc with key client_secret"
    red "  - check VSO logs: kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=50"
    exit 1
  fi
  sleep 5
done

# 7. Helm install
"$LIB/install-helm.sh" \
  --release kps --namespace "$NS" \
  --repo-name prometheus-community --repo-url https://prometheus-community.github.io/helm-charts \
  --chart prometheus-community/kube-prometheus-stack --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/kube-prometheus-stack.yaml"

# 8. Ingress + Certificate + NetworkPolicy
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/06-grafana-ingress.yaml"

# 9. PrometheusRules + the CT-log monitor (detective controls). 09-platform-alerts
#    was previously applied ad-hoc; wired here so a rebuild restores the alerts +
#    the ct-monitor CronJob (threat-model P2/P3 — see 20-ct-monitor.yaml).
#    10-app-alerts carries the app/security alert pack (OpenBaoSealed,
#    KeycloakHTTP5xxRate, SpiceDB, …) — it sat unwired from 2026-05-20 to
#    2026-07-06 and was never live (infra-sweep debt-1).
"$LIB/apply-manifest.sh" \
  "$PLATFORM_DIR/manifests/observability/09-platform-alerts.yaml" \
  "$PLATFORM_DIR/manifests/observability/10-app-alerts.yaml" \
  "$PLATFORM_DIR/manifests/observability/20-ct-monitor.yaml"

echo
green "✓ kube-prometheus-stack deployed."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods | grep -vE 'Running|Completed'"
echo "  kubectl -n $NS get certificate grafana-tls"
echo "  kubectl -n $NS get ingress grafana"
echo
echo "Grafana login: open https://grafana.$(grep DOMAIN= ${PLATFORM_DIR}/globals.env | cut -d= -f2)"
echo "  click 'Sign in with Keycloak' → bounce to auth.<domain> → passkey/TOTP → land as Admin"
