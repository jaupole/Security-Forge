#!/usr/bin/env bash
# Phase 7.5 — apply Tempo + OpenTelemetry Collector.
#
# Pre-conditions:
#   - Phase 7.4 complete (Loki up; minio loki-user provisioned; the
#     mc-user-creation pattern is proven).
#   - tempo-vso K8s auth role exists in OpenBao (added to
#     configure-openbao-role.sh in Phase 7.4 batch).
#   - tempo-traces bucket exists (added to bucket-bootstrap-job.yaml
#     in Phase 7.4 batch).
#   - BAO_TOKEN exported.
#
# What this script does:
#   1. Provisions MinIO user tempo-user with bucket-scoped policy on tempo-traces.
#   2. Stages the keys in OpenBao at secret/data/minio/tempo/credentials.
#   3. Applies the VSO binding so VSO renders tempo-minio-credentials.
#   4. helm upgrade --install tempo + opentelemetry-collector.

set -euo pipefail

NS=observability
TEMPO_RELEASE=tempo
OTEL_RELEASE=otel-collector
TEMPO_CHART=grafana/tempo
OTEL_CHART=open-telemetry/opentelemetry-collector
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.24.4}"
OTEL_CHART_VERSION="${OTEL_CHART_VERSION:-0.153.0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN not set"; exit 1; }

# ─── 1. Helm repos ─────────────────────────────────────────────────────
green "==> ensure helm repos (grafana + open-telemetry)"
for repo_name in grafana open-telemetry; do
    if ! helm repo list 2>/dev/null | grep -q "^${repo_name}\s"; then
        case "$repo_name" in
            grafana) helm repo add grafana https://grafana.github.io/helm-charts ;;
            open-telemetry) helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts ;;
        esac
    fi
done
helm repo update grafana open-telemetry >/dev/null

# ─── 2. Provision scoped MinIO user ────────────────────────────────────
green "==> provision MinIO user tempo-user (scoped to tempo-traces bucket)"
EXISTING_AK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=access_key secret/minio/tempo/credentials 2>/dev/null || true)
EXISTING_SK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=secret_key secret/minio/tempo/credentials 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
    yellow "    reusing existing keys from OpenBao"
    TEMPO_AK="$EXISTING_AK"
    TEMPO_SK="$EXISTING_SK"
else
    TEMPO_AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    TEMPO_SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
    green "    generated new keys"
fi

POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::tempo-traces/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::tempo-traces"]
    }
  ]
}
EOF
)

ROOT_USER=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
ROOT_PASS=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)

MINIO_POD=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && MINIO_POD=$(kubectl get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && { red "no MinIO pod found in minio namespace"; exit 1; }

kubectl exec -n minio "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-tempo-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${TEMPO_AK}' '${TEMPO_SK}'
cat > /tmp/tempo-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
mc admin policy create local tempo-policy /tmp/tempo-policy.json 2>/dev/null || \
    mc admin policy update local tempo-policy /tmp/tempo-policy.json
mc admin policy attach local tempo-policy --user '${TEMPO_AK}' || true
rm -f /tmp/tempo-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'tempo MinIO user provisioned and policy attached'
" 2>&1 | tail -10

# ─── 3. Stage creds in OpenBao ────────────────────────────────────────
green "==> stage tempo credentials in OpenBao"
kubectl exec -i -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv put secret/minio/tempo/credentials \
        access_key="$TEMPO_AK" \
        secret_key="$TEMPO_SK" >/dev/null

# ─── 4. VSO binding ───────────────────────────────────────────────────
green "==> apply VSO binding for Tempo MinIO credentials"
kubectl apply -f "$HERE/09-tempo-vso-binding.yaml"

green "==> waiting for VSO to render tempo-minio-credentials (up to 60s)"
for i in $(seq 1 12); do
    if kubectl -n "$NS" get secret tempo-minio-credentials >/dev/null 2>&1; then
        green "    rendered after $((i*5))s"
        break
    fi
    [ "$i" -eq 12 ] && { red "VSO did not render tempo-minio-credentials"; exit 1; }
    sleep 5
done

# ─── 5. helm install Tempo + OTel Collector ───────────────────────────
green "==> helm upgrade --install $TEMPO_RELEASE $TEMPO_CHART"
helm upgrade --install "$TEMPO_RELEASE" "$TEMPO_CHART" \
    --version "$TEMPO_CHART_VERSION" \
    --namespace "$NS" \
    -f "$HERE/07-tempo-values.yaml" \
    --wait --timeout 10m

green "==> helm upgrade --install $OTEL_RELEASE $OTEL_CHART"
helm upgrade --install "$OTEL_RELEASE" "$OTEL_CHART" \
    --version "$OTEL_CHART_VERSION" \
    --namespace "$NS" \
    -f "$HERE/08-otel-collector-values.yaml" \
    --wait --timeout 5m

green ""
green "Done."
green ""
green "Sanity:"
green "  kubectl -n $NS get pods | grep -E 'tempo|otel-collector'"
green "  # Send a test trace via OTel Collector OTLP gRPC port (4317):"
green "  # In Grafana → Explore → Tempo → search by service.name"
green ""
green "Trace propagation: BFF, AuthZEN, Keycloak (next in 7.6) emit OTLP"
green "to otel-collector.observability.svc:4317."
