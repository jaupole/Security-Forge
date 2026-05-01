#!/usr/bin/env bash
# Phase 7.3 — apply kube-prometheus-stack (Prometheus + Alertmanager +
# Grafana + node-exporter + kube-state-metrics) with OIDC-federated
# Grafana login.
#
# Pre-conditions (must be done in this order BEFORE running this script):
#   1. infrastructure/keycloak/clients/grafana.sh has been run; you
#      captured the printed grafana client_secret.
#   2. The grafana client_secret has been staged in OpenBao:
#        bao login -method=oidc role=admin
#        bao kv put secret/grafana/oidc client_secret='<from-grafana.sh>'
#   3. infrastructure/openbao/policies/vso.hcl has been re-applied
#      (Phase 7.3 added the grafana/oidc paths) AND
#      infrastructure/vault-secrets-operator/configure-openbao-role.sh
#      has been re-run (Phase 7.3 adds the grafana-vso K8s auth role):
#        BAO_TOKEN=$(bao print token) \
#          bash infrastructure/vault-secrets-operator/configure-openbao-role.sh
#
# What this script does:
#   1. Adds the prometheus-community Helm repo if not present.
#   2. Stages the mkcert CA into the observability namespace so Grafana
#      can verify Keycloak's OIDC TLS cert.
#   3. Applies the VSO binding so VSO renders grafana-oidc-client-secret.
#   4. Waits for the rendered Secret to appear (up to 60s).
#   5. helm install / upgrade kube-prometheus-stack.
#   6. Applies the Grafana ingress, certificate, and NetworkPolicies.
#
# Idempotent: re-runs are safe.

set -euo pipefail

NS=observability
RELEASE=kps
CHART=prometheus-community/kube-prometheus-stack
CHART_VERSION="${KPS_CHART_VERSION:-84.4.0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# ─── 1. Helm repo ──────────────────────────────────────────────────────
green "==> ensure prometheus-community Helm repo"
if helm repo list 2>/dev/null | grep -q '^prometheus-community\s'; then
    yellow "    already present"
else
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update prometheus-community >/dev/null

# ─── 2. mkcert CA bundle in observability ns ───────────────────────────
green "==> stage mkcert CA bundle into $NS namespace"
MKCERT_CA_SECRET=$(kubectl get clusterissuer mkcert-issuer \
    -o jsonpath='{.spec.ca.secretName}')
CA_CRT=$(kubectl get secret -n cert-manager "$MKCERT_CA_SECRET" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)

if kubectl -n "$NS" get secret mkcert-ca-bundle >/dev/null 2>&1; then
    yellow "    already present; refreshing"
fi
kubectl -n "$NS" create secret generic mkcert-ca-bundle \
    --from-literal=ca.crt="$CA_CRT" \
    --dry-run=client -o yaml | kubectl apply -f -

# ─── 3. VSO binding (Grafana OIDC client_secret rendering) ─────────────
green "==> apply VSO binding for Grafana OIDC secret"
kubectl apply -f "$HERE/00-grafana-vso-binding.yaml"

# Wait for the rendered Secret to appear.
green "==> waiting for VSO to render grafana-oidc-client-secret (up to 60s)"
for i in $(seq 1 12); do
    if kubectl -n "$NS" get secret grafana-oidc-client-secret \
            >/dev/null 2>&1; then
        green "    rendered after $((i*5))s"
        break
    fi
    if [ "$i" -eq 12 ]; then
        red "VSO did not render grafana-oidc-client-secret within 60s"
        red "  - confirm OpenBao has secret/data/grafana/oidc with key client_secret"
        red "  - confirm policies/vso.hcl was re-applied (re-run configure-openbao-role.sh)"
        red "  - check VSO logs:"
        red "      kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager"
        exit 1
    fi
    sleep 5
done

# ─── 4. Helm install/upgrade ───────────────────────────────────────────
green "==> helm upgrade --install $RELEASE $CHART"
helm upgrade --install "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    --create-namespace \
    -f "$HERE/01-kube-prometheus-stack-values.yaml" \
    --wait \
    --timeout 10m

# ─── 5. Ingress + Certificate + NetworkPolicies ───────────────────────
green "==> apply Grafana ingress + certificate + network policies"
kubectl apply -f "$HERE/02-grafana-ingress.yaml"

green ""
green "Done."
green ""
green "Sanity:"
green "  kubectl -n $NS get pods"
green "  kubectl -n $NS get certificates"
green "  curl -sk https://grafana.secforge.local/api/health     # expect {\"database\":\"ok\"...}"
green ""
green "Login: open https://grafana.secforge.local in a browser, click 'Sign in"
green "with Keycloak'. Will bounce to https://auth.secforge.local, accept your"
green "passkey/TOTP, return as Grafana Admin (mapped from realm role"
green "platform_admin)."
