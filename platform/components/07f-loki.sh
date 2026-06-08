#!/usr/bin/env bash
# 07f — Loki + scoped MinIO user.
#
# Same pattern as 07b-tempo.sh but for the loki-chunks bucket.
#
# Pre-conditions:
#   - 07a (MinIO + buckets), 07e (kube-prometheus-stack with ServiceMonitor CRDs)
#   - openbao-root-token-tmp Secret in openbao ns

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${LOKI_CHART_VER:-7.0.0}"
NS=observability
NS_BAO=openbao
NS_MINIO=minio
POD_BAO=openbao-0

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found."; exit 1
fi
if ! kubectl -n "$NS_MINIO" get secret minio-root-credentials >/dev/null 2>&1; then
  red "ERROR: minio-root-credentials not found. Run 07a-minio.sh first."; exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. Provision (or reuse) Loki MinIO user
green "==> provision MinIO user loki-user (scoped to loki-chunks)"
EXISTING_AK=$(bao bao kv get -field=access_key secret/minio/loki/credentials 2>/dev/null || true)
EXISTING_SK=$(bao bao kv get -field=secret_key secret/minio/loki/credentials 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
  yellow "    reusing existing keys from OpenBao"
  LOKI_AK="$EXISTING_AK"; LOKI_SK="$EXISTING_SK"
else
  LOKI_AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
  LOKI_SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  green "    generated new keys"
fi

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

ROOT_USER=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
ROOT_PASS=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)

MINIO_POD=$(kubectl get pods -n "$NS_MINIO" -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && MINIO_POD=$(kubectl get pods -n "$NS_MINIO" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && { red "no MinIO pod found"; exit 1; }

green "==> mc admin user add + policy attach (in MinIO pod)"
kubectl exec -n "$NS_MINIO" "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-loki-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${LOKI_AK}' '${LOKI_SK}' 2>&1 | tail -1 || true
cat > /tmp/loki-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
mc admin policy create local loki-policy /tmp/loki-policy.json 2>/dev/null || \
    mc admin policy update local loki-policy /tmp/loki-policy.json
mc admin policy attach local loki-policy --user '${LOKI_AK}' 2>/dev/null || true
rm -f /tmp/loki-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'loki MinIO user provisioned and policy attached'
" 2>&1 | tail -5

unset ROOT_USER ROOT_PASS

# 2. Stage creds in OpenBao
green "==> stage loki credentials at secret/minio/loki/credentials"
bao bao kv put secret/minio/loki/credentials \
    access_key="$LOKI_AK" \
    secret_key="$LOKI_SK" >/dev/null
unset LOKI_AK LOKI_SK

# 3. Re-load vso policy (already has loki path)
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 4. Apply VSO binding
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/07-loki-vso-binding.yaml"

# 5. K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: loki-vso"
bao bao write auth/kubernetes/role/loki-vso \
  bound_service_account_names="loki-vso" \
  bound_service_account_namespaces="observability" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 6. Wait for VSO render
green "==> waiting for VSO to render loki-minio-credentials (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret loki-minio-credentials >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render loki-minio-credentials within 60s"; exit 1
  fi
  sleep 5
done

# 7. Helm install
"$LIB/install-helm.sh" \
  --release loki --namespace "$NS" \
  --repo-name grafana --repo-url https://grafana.github.io/helm-charts \
  --chart grafana/loki --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/loki.yaml"

# 8. Loki audit anchor + verifier (operator-backlog #85 Phase 2 / threat-model
#    X-R1) — tamper-evident anchoring of the Loki log sink. Ships SUSPENDED; the
#    platform-loki-audit-signer OpenBao role is created in 05j and the OpenBao CA
#    reaches this ns via the trust-manager openbao-internal-ca-cert Bundle (which
#    now selects observability — 06-trust-manager.sh). Activate per
#    docs/03-runbooks/platform-loki-audit-anchor.md.
"$LIB/apply-manifest.sh" \
  "$PLATFORM_DIR/manifests/observability/21-loki-audit-anchor.yaml" \
  "$PLATFORM_DIR/manifests/observability/22-loki-audit-verifier.yaml"

echo
green "✓ Loki deployed."
echo "Sanity:"
echo "  kubectl -n $NS get pods | grep loki"
echo "  kubectl -n $NS logs sts/loki --tail=30"
