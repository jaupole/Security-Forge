#!/usr/bin/env bash
# 01 — CloudNativePG operator
# Reusable Postgres-on-K8s. Provides Cluster CRs for keycloak, spicedb, openbao, app DBs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

"$LIB/install-helm.sh" \
  --release cnpg \
  --namespace postgres-operator \
  --repo-name cnpg --repo-url https://cloudnative-pg.github.io/charts \
  --chart cnpg/cloudnative-pg \
  --values "$PLATFORM_DIR/values/cloudnativepg.yaml"

echo ">>> Waiting for CloudNativePG operator to be Ready..."
kubectl rollout status deployment/cnpg-cloudnative-pg -n postgres-operator --timeout=300s

echo "✓ CloudNativePG operator deployed."
echo
echo "Verify:"
echo "  kubectl get pods -n postgres-operator"
echo "  kubectl get crd | grep postgresql"
