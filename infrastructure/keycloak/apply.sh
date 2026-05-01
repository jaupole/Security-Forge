#!/usr/bin/env bash
# Idempotent installer for Keycloak (Phase 3.2).
# Safe to re-run: existing resources are kept, missing resources are created.
#
# What this does:
#   1. Apply Operator CRDs and operator deployment (keycloak namespace).
#   2. Create the bootstrap-admin Secret with a freshly generated 32-char
#      password — IF the Secret does not already exist. Print the password
#      once. The password is bootstrap-only.
#   3. Apply the rest of the manifests (SA, certs, Keycloak CR, ingress).
#   4. Wait for the StatefulSet to roll and the Keycloak CR to report Ready.
#
# What this does NOT do:
#   - Configure realms, clients, flows. That happens in Phase 3.4 / 3.5.
#   - Create the admin Ingress or NetworkPolicies. That happens in Phase 3.6.

set -euo pipefail

NS="keycloak"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}

require_cmd kubectl
require_cmd openssl

# 1. Operator CRDs + operator deployment.
green "==> Installing Keycloak Operator CRDs"
kubectl apply -f "${HERE}/operator/keycloaks.crd.yaml"
kubectl apply -f "${HERE}/operator/keycloakrealmimports.crd.yaml"

green "==> Installing Keycloak Operator (namespace: ${NS})"
# Apply via kustomize so our PSS-restricted security-context overlay
# is layered on the upstream-pristine operator.yaml.
kubectl apply -k "${HERE}/operator"

green "==> Waiting for operator to be Ready"
kubectl -n "${NS}" rollout status deployment/keycloak-operator --timeout=180s

# 2. Bootstrap admin Secret (generate-on-first-run, keep on subsequent runs).
if ! kubectl -n "${NS}" get secret keycloak-bootstrap-admin >/dev/null 2>&1; then
    green "==> Generating bootstrap admin Secret"
    BOOTSTRAP_PW="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    kubectl create secret generic keycloak-bootstrap-admin \
        --namespace "${NS}" \
        --from-literal=username=bootstrap-admin \
        --from-literal=password="${BOOTSTRAP_PW}"
    kubectl -n "${NS}" label secret keycloak-bootstrap-admin \
        app.kubernetes.io/name=keycloak \
        secforge.platform/component=keycloak \
        secforge.platform/purpose=bootstrap-only \
        --overwrite
    yellow ""
    yellow "============================================================"
    yellow "BOOTSTRAP ADMIN CREDENTIALS — copy now, shown once:"
    yellow "  username: bootstrap-admin"
    yellow "  password: ${BOOTSTRAP_PW}"
    yellow ""
    yellow "Use these to log into the admin console once Phase 3.6 is"
    yellow "done (https://auth-admin.secforge.local/admin/), then delete"
    yellow "the Secret after switching to your TOTP-protected user:"
    yellow "  kubectl -n ${NS} delete secret keycloak-bootstrap-admin"
    yellow "============================================================"
    yellow ""
    unset BOOTSTRAP_PW
else
    green "==> Bootstrap admin Secret already exists; skipping generation"
fi

# 3. ServiceAccount, certs, Keycloak CR, public ingress.
green "==> Applying ServiceAccount"
kubectl apply -f "${HERE}/01-serviceaccount.yaml"

green "==> Applying TLS Certificates"
kubectl apply -f "${HERE}/03-certificate.yaml"

green "==> Applying Keycloak CR"
kubectl apply -f "${HERE}/04-keycloak-cr.yaml"

green "==> Applying public Ingress"
kubectl apply -f "${HERE}/05-ingress-public.yaml"

# 4. Wait for the operator to roll the StatefulSet and the CR to be Ready.
green "==> Waiting for Keycloak StatefulSet to be created (operator may take ~30s)"
for i in {1..30}; do
    if kubectl -n "${NS}" get statefulset keycloak >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

green "==> Waiting for Keycloak pod to be Ready (first start can take ~3 minutes)"
kubectl -n "${NS}" rollout status statefulset/keycloak --timeout=600s

green "==> Waiting for Keycloak CR to report Ready=True"
kubectl wait -n "${NS}" --for=condition=Ready --timeout=300s keycloak/keycloak

green ""
green "Keycloak is up. Verify discovery doc:"
green "  curl -ks https://auth.secforge.local/realms/master/.well-known/openid-configuration | jq ."
green ""
