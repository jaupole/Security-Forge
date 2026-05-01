#!/usr/bin/env bash
# Phase 7.4 — apply Loki + Promtail.
#
# Pre-conditions:
#   - Phase 7.3 complete (Grafana up, Prometheus reachable, observability
#     namespace + grafana-vso K8s Secret rendering working).
#   - infrastructure/openbao/policies/vso.hcl re-applied (Phase 7.4 added
#     minio/loki paths) AND
#     infrastructure/vault-secrets-operator/configure-openbao-role.sh
#     re-run (added loki-vso K8s auth role):
#         BAO_TOKEN=$(bao print token) \
#           bash infrastructure/vault-secrets-operator/configure-openbao-role.sh
#   - infrastructure/minio/bucket-bootstrap-job.yaml re-applied (added
#     loki-chunks bucket).
#   - Operator has run `bao login -method=oidc role=admin` and exported
#     BAO_TOKEN. Same token is used to write the MinIO user creds.
#
# What this script does:
#   1. Provisions a scoped MinIO user `loki-user` with policy allowing
#      s3 R/W against the loki-chunks bucket only.
#   2. Stages the user's access keys into OpenBao at
#      secret/data/minio/loki/credentials.
#   3. Applies the VSO binding (05-loki-vso-binding.yaml) so VSO renders
#      the K8s Secret loki-minio-credentials.
#   4. helm upgrade --install loki + promtail.
#   5. Applies the Grafana Loki datasource ConfigMap.
#
# Idempotent: re-runs are safe (mc admin user add and bao kv put both
# overwrite cleanly; helm upgrade is no-op on identical values).

set -euo pipefail

NS=observability
LOKI_RELEASE=loki
PROMTAIL_RELEASE=promtail
LOKI_CHART=grafana/loki
PROMTAIL_CHART=grafana/promtail
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.0.0}"
PROMTAIL_CHART_VERSION="${PROMTAIL_CHART_VERSION:-6.17.1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN not set; bao login -method=oidc role=admin first"; exit 1; }

# ─── 1. Helm repo ──────────────────────────────────────────────────────
green "==> ensure grafana Helm repo"
if helm repo list 2>/dev/null | grep -q '^grafana\s'; then
    yellow "    already present"
else
    helm repo add grafana https://grafana.github.io/helm-charts
fi
helm repo update grafana >/dev/null

# ─── 2. Provision scoped MinIO user ────────────────────────────────────
green "==> provision MinIO user loki-user (scoped to loki-chunks bucket)"

# Generate per-install access keys. If they already exist in OpenBao
# (re-run), reuse them so MinIO and OpenBao stay aligned.
EXISTING_AK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=access_key secret/minio/loki/credentials 2>/dev/null || true)
EXISTING_SK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=secret_key secret/minio/loki/credentials 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
    yellow "    reusing existing keys from OpenBao"
    LOKI_AK="$EXISTING_AK"
    LOKI_SK="$EXISTING_SK"
else
    LOKI_AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    LOKI_SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
    green "    generated new keys"
fi

# Build the scoped policy JSON.
POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::loki-chunks/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::loki-chunks"]
    }
  ]
}
EOF
)

# Run mc admin commands inside a transient pod (mc image with restricted
# Pod Security context). Same image the bucket-bootstrap-job uses.
green "==> mc admin user add + policy attach (transient pod in minio ns)"
ROOT_USER=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
ROOT_PASS=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)

# Find the MinIO pod by label (release name varies; the chart's label is
# app=minio in default chart, app.kubernetes.io/name=minio in newer ones).
MINIO_POD=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && MINIO_POD=$(kubectl get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && { red "no MinIO pod found in minio namespace"; exit 1; }

# mc is already installed at /usr/bin/mc inside the minio pod, and /tmp
# is writable. Avoids the transient-pod-with-readonly-rootfs issue we hit
# in earlier iterations of this script.
kubectl exec -n minio "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-loki-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${LOKI_AK}' '${LOKI_SK}'
cat > /tmp/loki-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
mc admin policy create local loki-policy /tmp/loki-policy.json 2>/dev/null || \
    mc admin policy update local loki-policy /tmp/loki-policy.json
mc admin policy attach local loki-policy --user '${LOKI_AK}' || true
rm -f /tmp/loki-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'loki MinIO user provisioned and policy attached'
" 2>&1 | tail -10

# ─── 3. Stage creds in OpenBao ─────────────────────────────────────────
green "==> stage loki credentials in OpenBao"
kubectl exec -i -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv put secret/minio/loki/credentials \
        access_key="$LOKI_AK" \
        secret_key="$LOKI_SK" >/dev/null

# ─── 4. VSO binding ────────────────────────────────────────────────────
green "==> apply VSO binding for Loki MinIO credentials"
kubectl apply -f "$HERE/05-loki-vso-binding.yaml"

green "==> waiting for VSO to render loki-minio-credentials (up to 60s)"
for i in $(seq 1 12); do
    if kubectl -n "$NS" get secret loki-minio-credentials >/dev/null 2>&1; then
        green "    rendered after $((i*5))s"
        break
    fi
    if [ "$i" -eq 12 ]; then
        red "VSO did not render loki-minio-credentials within 60s"
        red "  - confirm OpenBao has secret/data/minio/loki/credentials with keys access_key + secret_key"
        red "  - confirm policies/vso.hcl re-applied AND configure-openbao-role.sh re-run"
        exit 1
    fi
    sleep 5
done

# ─── 5. helm install Loki + Promtail ──────────────────────────────────
green "==> helm upgrade --install $LOKI_RELEASE $LOKI_CHART"
helm upgrade --install "$LOKI_RELEASE" "$LOKI_CHART" \
    --version "$LOKI_CHART_VERSION" \
    --namespace "$NS" \
    -f "$HERE/03-loki-values.yaml" \
    --wait --timeout 10m

green "==> helm upgrade --install $PROMTAIL_RELEASE $PROMTAIL_CHART"
helm upgrade --install "$PROMTAIL_RELEASE" "$PROMTAIL_CHART" \
    --version "$PROMTAIL_CHART_VERSION" \
    --namespace "$NS" \
    -f "$HERE/04-promtail-values.yaml" \
    --wait --timeout 5m

# ─── 6. Grafana Loki datasource ConfigMap ─────────────────────────────
green "==> apply Grafana Loki datasource (ConfigMap, picked up by sidecar)"
kubectl apply -f "$HERE/06-grafana-datasources-extra.yaml"

green ""
green "Done."
green ""
green "Sanity:"
green "  kubectl -n $NS get pods | grep -E 'loki|promtail'"
green "  kubectl -n $NS logs deploy/loki | head -20"
green "  # In Grafana, Connections → Datasources → Loki → Test"
green ""
green "Query Loki from Grafana (Explore): {namespace=\"keycloak\"} | json | line_format \"{{.msg}}\""
