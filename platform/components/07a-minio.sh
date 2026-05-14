#!/usr/bin/env bash
# 07a — MinIO (in-cluster S3 substitute) + bucket bootstrap.
#
# Storage backend for Tempo (now), Loki / Wazuh-archive / Teleport-recordings
# (Phase 7-rest / Phase 8). Console NOT exposed via Ingress; admin access
# is `kubectl port-forward -n minio svc/minio 9001:9001` then login with
# minio-root-credentials.
#
# What this does:
#   1. Apply the minio namespace (restricted PSA).
#   2. Create minio-root-credentials Secret if it doesn't exist
#      (rootUser=secforge-admin, rootPassword=$(openssl rand -base64 32)).
#   3. Helm install/upgrade MinIO (standalone, ClusterIP, no ingress).
#   4. Apply the bucket bootstrap Job (idempotent — re-runs are no-ops).
#
# Idempotent. The root password is generated ONCE on first run and reused
# thereafter. To rotate: delete the secret + restart MinIO + re-deploy
# all consumers (they'll re-fetch via VSO on the next refresh).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${MINIO_CHART_VER:-5.4.0}"
NS=minio

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/minio/01-namespace.yaml"

# 2. Root credentials Secret (generated once, persisted)
if ! kubectl -n "$NS" get secret minio-root-credentials >/dev/null 2>&1; then
  echo ">>> Generating MinIO root credentials (one-time)"
  ROOT_USER=secforge-admin
  ROOT_PASS=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)
  kubectl -n "$NS" create secret generic minio-root-credentials \
    --from-literal=rootUser="$ROOT_USER" \
    --from-literal=rootPassword="$ROOT_PASS"
  unset ROOT_PASS
  echo "    minio-root-credentials created"
else
  echo ">>> minio-root-credentials already exists — reusing"
fi

# 3. Helm install
"$LIB/install-helm.sh" \
  --release minio --namespace "$NS" \
  --repo-name minio --repo-url https://charts.min.io \
  --chart minio/minio --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/minio.yaml"

# 4. Cross-namespace client NetworkPolicy (additive — co-exists with chart NP)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/minio/03-allow-cross-ns-clients.yaml"

# 5. Bucket bootstrap Job
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/minio/02-bucket-bootstrap-job.yaml"

# Wait for the Job to complete (or fail) — useful signal in CI/runbook.
echo ">>> Waiting for bucket-bootstrap Job to complete (up to 2m)"
kubectl -n "$NS" wait --for=condition=complete --timeout=120s \
  job/minio-bucket-bootstrap || {
    echo "WARN: bucket-bootstrap Job did not complete cleanly. Logs:"
    kubectl -n "$NS" logs job/minio-bucket-bootstrap --tail=50 || true
    exit 1
  }

echo
echo "✓ MinIO deployed. Buckets:"
kubectl -n "$NS" logs job/minio-bucket-bootstrap --tail=20 | grep -A 20 '^--- buckets'
echo
echo "Console (admin):"
echo "  kubectl -n $NS port-forward svc/minio-console 9001:9001"
echo "  open http://localhost:9001"
echo "  user/pass: \$(kubectl -n $NS get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d) / ...rootPassword"
