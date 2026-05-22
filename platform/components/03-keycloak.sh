#!/usr/bin/env bash
# 03 — Keycloak (identity provider)
#
# Depends on: 01-cloudnativepg (provides the postgres operator that creates
# the secforge-keycloak-db Cluster), 02-spire (provides workload identity for
# spiffe.io/spire-managed-identity-labeled pods).
#
# Installs in this order:
#   1. Namespace (PSS restricted)
#   2. Operator CRDs
#   3. Operator (kustomize overlay applies PSS-compliant security context)
#   4. CloudNativePG Cluster CR (Postgres for Keycloak)
#   5. Bootstrap admin Secret (generated, password retrievable via kubectl)
#   6. ServiceAccount
#   7. Keycloak CR
#   8. Ingress with Let's Encrypt auto-issuance
#
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/keycloak"

# Source globals so closing echo can reference ${DOMAIN}
# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

# 1. Namespace
echo ">>> Creating keycloak namespace"
kubectl apply -f "$M/01-namespace.yaml"

# 1b. Layer-A egress baseline — per-namespace allows (operator-backlog #51).
kubectl apply -f "$M/09-egress-otel.yaml"
kubectl apply -f "$M/10-egress-to-minio.yaml"

# 2. Operator CRDs
echo ">>> Installing Keycloak Operator CRDs"
kubectl apply -f "$M/operator/keycloaks.crd.yaml"
kubectl apply -f "$M/operator/keycloakrealmimports.crd.yaml"

# 3. Operator (with kustomize overlay for PSS-restricted security context)
echo ">>> Installing Keycloak Operator (with security overlay)"
kubectl apply -k "$M/operator"
echo ">>> Waiting for operator to be Ready"
kubectl -n keycloak rollout status deployment/keycloak-operator --timeout=300s

# 4. CloudNativePG Cluster (envsubst for ${STORAGE_CLASS})
echo ">>> Creating CloudNativePG cluster for Keycloak"
"$LIB/apply-manifest.sh" "$M/02-cnpg-cluster.yaml"

# 5. Bootstrap admin Secret (idempotent — generates only on first run)
if ! kubectl -n keycloak get secret keycloak-bootstrap-admin >/dev/null 2>&1; then
  echo ">>> Generating bootstrap admin Secret"
  BOOTSTRAP_PW="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  kubectl create secret generic keycloak-bootstrap-admin \
    --namespace keycloak \
    --from-literal=username=bootstrap-admin \
    --from-literal=password="$BOOTSTRAP_PW"
  kubectl -n keycloak label secret keycloak-bootstrap-admin \
    app.kubernetes.io/name=keycloak \
    secforge.platform/component=keycloak \
    secforge.platform/purpose=bootstrap-only \
    --overwrite
  unset BOOTSTRAP_PW
  cat <<'BANNER'

================================================================
  Bootstrap admin Secret created.

  Retrieve username + password (DO NOT echo into this terminal):
    kubectl -n keycloak get secret keycloak-bootstrap-admin \
      -o jsonpath='{.data.username}' | base64 -d
    kubectl -n keycloak get secret keycloak-bootstrap-admin \
      -o jsonpath='{.data.password}' | base64 -d

  Use to log into Keycloak admin console once Keycloak is Ready,
  create a permanent admin with TOTP, then delete this Secret:
    kubectl -n keycloak delete secret keycloak-bootstrap-admin
================================================================
BANNER
else
  echo ">>> Bootstrap admin Secret already exists; skipping generation"
fi

# 6. ServiceAccount
kubectl apply -f "$M/03-serviceaccount.yaml"

# 7. Keycloak CR (envsubst for ${DOMAIN})
# Server-side apply: the live CR's kubectl.kubernetes.io/last-applied-
# configuration annotation is corrupt (carries metadata.resourceVersion from a
# past apply of a raw `kubectl get -o yaml` dump), which breaks client-side
# apply's 3-way merge. SSA does not use that annotation. See operator-backlog #52.
echo ">>> Applying Keycloak CR (server-side)"
"$LIB/apply-manifest.sh" --server-side "$M/04-keycloak-cr.yaml"

# 8. Ingress (envsubst for ${DOMAIN}, ${LE_ISSUER})
echo ">>> Applying Ingress"
"$LIB/apply-manifest.sh" "$M/05-ingress.yaml"

# Wait for the operator to create the StatefulSet (~30s)
echo ">>> Waiting for Keycloak StatefulSet to be created (operator may take ~30s)"
for _ in {1..60}; do
  if kubectl -n keycloak get statefulset keycloak >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo ">>> Waiting for Keycloak StatefulSet rollout (first start can take ~3 minutes)"
kubectl -n keycloak rollout status statefulset/keycloak --timeout=600s

echo ">>> Waiting for Keycloak CR to report Ready=True"
kubectl wait -n keycloak --for=condition=Ready --timeout=300s keycloak/keycloak

echo
echo "✓ Keycloak deployed."
echo
echo "Verify discovery doc (will return JSON when fully up):"
echo "  curl -s https://auth.${DOMAIN}/realms/master/.well-known/openid-configuration | jq -r .issuer"
echo
echo "Bootstrap admin password (run on the box):"
echo "  kubectl -n keycloak get secret keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d"
