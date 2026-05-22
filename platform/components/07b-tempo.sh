#!/usr/bin/env bash
# 07b — Tempo trace store + MinIO scoped user.
#
# Order of operations (each step is idempotent):
#   1. Apply observability namespace + base NetworkPolicies.
#   2. Provision MinIO user `tempo-user` with bucket-scoped policy on
#      tempo-traces (re-uses existing keys from OpenBao if present).
#   3. Stage access keys at OpenBao secret/data/minio/tempo/credentials.
#   4. Re-load vso.hcl policy so VSO can read the tempo path.
#   5. Apply VSO binding (SA + VaultAuth + VaultStaticSecret) in observability ns.
#   6. Create OpenBao K8s auth role tempo-vso (binds SA → vso policy).
#   7. Wait for VSO to render `tempo-minio-credentials` Secret.
#   8. Helm install Tempo.
#
# Pre-conditions:
#   - 05c-i (OpenBao Layer 1+2) complete, VSO operational.
#   - 07a-minio.sh has been run (minio ns, root creds, tempo-traces bucket).
#   - openbao-root-token-tmp Secret in openbao ns (paste from 1Password).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${TEMPO_CHART_VER:-1.24.4}"
NS=observability
NS_BAO=openbao
NS_MINIO=minio
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
if ! kubectl -n "$NS_MINIO" get secret minio-root-credentials >/dev/null 2>&1; then
  red "ERROR: minio-root-credentials not found. Run 07a-minio.sh first."
  exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. Namespace + base NetworkPolicies
green "==> apply observability namespace + base NetworkPolicies"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/01-namespace.yaml"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/02-default-deny-ingress.yaml"
# Layer-A egress baseline — per-namespace allows (operator-backlog #51).
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/11-egress-cluster-internal.yaml"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/12-egress-to-public-443.yaml"

# 2. Provision (or reuse) Tempo MinIO user + scoped policy
green "==> provision MinIO user tempo-user (scoped to tempo-traces)"

EXISTING_AK=$(bao bao kv get -field=access_key secret/minio/tempo/credentials 2>/dev/null || true)
EXISTING_SK=$(bao bao kv get -field=secret_key secret/minio/tempo/credentials 2>/dev/null || true)

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

ROOT_USER=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
ROOT_PASS=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)

MINIO_POD=$(kubectl get pods -n "$NS_MINIO" -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && MINIO_POD=$(kubectl get pods -n "$NS_MINIO" -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$MINIO_POD" ] && { red "no MinIO pod found"; exit 1; }

green "==> mc admin user add + policy attach (in MinIO pod)"
kubectl exec -n "$NS_MINIO" "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-tempo-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${TEMPO_AK}' '${TEMPO_SK}' 2>&1 | tail -1 || true
cat > /tmp/tempo-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
mc admin policy create local tempo-policy /tmp/tempo-policy.json 2>/dev/null || \
    mc admin policy update local tempo-policy /tmp/tempo-policy.json
mc admin policy attach local tempo-policy --user '${TEMPO_AK}' 2>/dev/null || true
rm -f /tmp/tempo-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'tempo MinIO user provisioned and policy attached'
" 2>&1 | tail -5

unset ROOT_USER ROOT_PASS

# 3. Stage creds in OpenBao
green "==> stage tempo credentials at secret/minio/tempo/credentials"
bao bao kv put secret/minio/tempo/credentials \
    access_key="$TEMPO_AK" \
    secret_key="$TEMPO_SK" >/dev/null
unset TEMPO_AK TEMPO_SK

# 4. Re-load vso.hcl (already has tempo path; re-load is idempotent)
green "==> re-load vso policy (ensures tempo path is permitted)"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 5. Apply VSO binding
green "==> apply VSO binding in observability namespace"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/03-tempo-vso-binding.yaml"

# 6. Create OpenBao K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: tempo-vso"
bao bao write auth/kubernetes/role/tempo-vso \
  bound_service_account_names="tempo-vso" \
  bound_service_account_namespaces="observability" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 7. Wait for VSO to render the K8s Secret
green "==> waiting for VSO to render tempo-minio-credentials (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret tempo-minio-credentials >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"
    break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render tempo-minio-credentials within 60s"
    red "  - confirm OpenBao has secret/data/minio/tempo/credentials with access_key + secret_key"
    red "  - confirm vso policy was re-loaded (step 4)"
    red "  - check VSO logs:"
    red "      kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=50"
    exit 1
  fi
  sleep 5
done

# Sanity: confirm the rendered Secret has both keys
KEYS=$(kubectl -n "$NS" get secret tempo-minio-credentials -o jsonpath='{.data}' | grep -oE 'ACCESS_KEY|SECRET_KEY' | sort -u | tr '\n' ' ')
if [[ "$KEYS" != *"ACCESS_KEY"* || "$KEYS" != *"SECRET_KEY"* ]]; then
  red "ERROR: tempo-minio-credentials missing required keys. Got: $KEYS"
  exit 1
fi
green "    keys present: ACCESS_KEY, SECRET_KEY"

# 8. Helm install Tempo
"$LIB/install-helm.sh" \
  --release tempo --namespace "$NS" \
  --repo-name grafana --repo-url https://grafana.github.io/helm-charts \
  --chart grafana/tempo --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/tempo.yaml"

echo
green "✓ Tempo deployed."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods -l app.kubernetes.io/name=tempo"
echo "  kubectl -n $NS logs sts/tempo --tail=30"
echo "  # Test query (should return empty list initially):"
echo "  kubectl -n $NS port-forward svc/tempo 3200:3200 &"
echo "  curl -s http://localhost:3200/api/search | head"
