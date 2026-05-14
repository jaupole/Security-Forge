#!/usr/bin/env bash
# 09b — CloudNativePG physical backups + WAL archiving → MinIO `backups`
# bucket (prefix `cnpg/<cluster>`).
#
# Order of operations (idempotent):
#   1. Provision (or reuse) MinIO user `cnpg-user` with prefix-scoped
#      policy on backups/cnpg/* in the `backups` bucket. This is a SHARED
#      user across all CNPG clusters (each cluster writes to its own
#      sub-prefix; access control is bucket-level prefix).
#   2. Stage keys at OpenBao secret/data/minio/cnpg/credentials.
#   3. Re-load vso.hcl policy.
#   4. Apply per-namespace VSO bindings (keycloak, spicedb).
#   5. Create per-namespace OpenBao K8s auth roles (cnpg-keycloak-vso,
#      cnpg-spicedb-vso). Each role is bound to the SAME vso policy and
#      the SAME `cnpg-vso` SA in its respective namespace.
#   6. Wait for VSO renders.
#   7. Re-apply the patched CNPG cluster YAMLs (now with `backup` block).
#      CNPG operator picks up the change and starts WAL archiving.
#   8. Apply ScheduledBackup CRs (daily base backups).
#   9. Trigger an immediate Backup per cluster to verify pipeline.
#
# Pre-conditions:
#   - 07a-minio.sh complete (MinIO + `backups` bucket + cross-ns NP).
#   - 09a-velero.sh complete (NOT a hard dep but the policy update they
#     share is loaded once by 09a; this is fine either order).
#   - openbao-root-token-tmp Secret in openbao ns.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

NS_BAO=openbao
NS_MINIO=minio
POD_BAO=openbao-0

CLUSTERS=("keycloak:secforge-keycloak-db" "spicedb:secforge-spicedb-db")

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

# 1. Provision (or reuse) shared CNPG MinIO user
green "==> provision MinIO user cnpg-user (scoped to backups/cnpg/*)"

EXISTING_AK=$(bao bao kv get -field=access_key secret/minio/cnpg/credentials 2>/dev/null || true)
EXISTING_SK=$(bao bao kv get -field=secret_key secret/minio/cnpg/credentials 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
  yellow "    reusing existing keys from OpenBao"
  CNPG_AK="$EXISTING_AK"; CNPG_SK="$EXISTING_SK"
else
  CNPG_AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
  CNPG_SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  green "    generated new keys"
fi

# See 09a for the no-Condition rationale.
POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::backups/cnpg/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::backups"]
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

green "==> mc admin user add + policy attach"
kubectl exec -n "$NS_MINIO" "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-cnpg-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${CNPG_AK}' '${CNPG_SK}' 2>&1 | tail -1 || true
cat > /tmp/cnpg-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
# `mc admin policy update` is deprecated in newer mc; create handles
# both create and overwrite when given a file. Suppress create's error
# if the policy already exists (idempotent path).
mc admin policy create local cnpg-policy /tmp/cnpg-policy.json 2>&1 || true
mc admin policy attach local cnpg-policy --user '${CNPG_AK}' 2>/dev/null || true
rm -f /tmp/cnpg-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'cnpg MinIO user provisioned and policy attached'
" 2>&1 | tail -5

unset ROOT_USER ROOT_PASS

# 2. Stage creds in OpenBao
green "==> stage cnpg credentials at secret/minio/cnpg/credentials"
bao bao kv put secret/minio/cnpg/credentials \
    access_key="$CNPG_AK" \
    secret_key="$CNPG_SK" >/dev/null
unset CNPG_AK CNPG_SK

# 3. Re-load vso policy
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 4-6. Per-cluster: VSO binding + K8s auth role + wait for render
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  cluster="${entry##*:}"

  green "==> apply VSO binding in $ns"
  "$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/$ns/06-cnpg-vso-binding.yaml"

  green "==> write OpenBao K8s auth role: cnpg-${ns}-vso"
  bao bao write "auth/kubernetes/role/cnpg-${ns}-vso" \
    bound_service_account_names="cnpg-vso" \
    bound_service_account_namespaces="$ns" \
    audience="$K8S_AUDIENCE" \
    policies="vso" \
    ttl="1h" \
    max_ttl="24h" 2>&1 | tail -1

  green "==> waiting for VSO render of cnpg-minio-credentials in $ns (up to 60s)"
  for i in $(seq 1 12); do
    if kubectl -n "$ns" get secret cnpg-minio-credentials >/dev/null 2>&1; then
      green "    rendered after $((i*5))s"; break
    fi
    if [ "$i" -eq 12 ]; then
      red "ERROR: VSO did not render cnpg-minio-credentials in $ns within 60s"; exit 1
    fi
    sleep 5
  done
done

unset ROOT_TOKEN

# 7. Re-apply patched CNPG cluster YAMLs (now with backup block).
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  green "==> re-apply $ns/02-cnpg-cluster.yaml (now with backup block)"
  "$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/$ns/02-cnpg-cluster.yaml"
done

# 8. ScheduledBackup CRs
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  green "==> apply $ns/07-cnpg-scheduled-backup.yaml"
  "$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/$ns/07-cnpg-scheduled-backup.yaml"
done

# 9. Trigger an immediate one-shot Backup per cluster for pipeline verification.
#    CNPG operator needs ~30s to pick up the new backup config and start WAL
#    archiving; the on-demand Backup waits for that.
green "==> waiting 30s for CNPG operator to pick up backup config"
sleep 30

for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  cluster="${entry##*:}"
  bk_name="${cluster}-initial-$(date -u +%Y%m%d-%H%M%S)"
  green "==> trigger initial Backup: $ns/$bk_name"
  kubectl create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $bk_name
  namespace: $ns
  labels:
    secforge.platform/component: cloudnativepg
    secforge.platform/cluster: $cluster
    secforge.platform/purpose: bootstrap-verification
spec:
  cluster:
    name: $cluster
EOF
done

echo
green "✓ CNPG backups wired."
echo
echo "Sanity:"
echo "  kubectl -n keycloak get backup,scheduledbackup"
echo "  kubectl -n spicedb  get backup,scheduledbackup"
echo "  kubectl -n keycloak describe cluster secforge-keycloak-db | grep -A 5 Backup"
echo
echo "Inspect MinIO contents:"
echo "  kubectl -n minio port-forward svc/minio-console 9001:9001 &"
echo "  open http://localhost:9001 → bucket: backups → prefix: cnpg/keycloak, cnpg/spicedb"
echo
echo "Restore drill (later, separate deployment session):"
echo "  Create a new Cluster CR with bootstrap.recovery.backup.name=<initial-backup>"
echo "  to validate end-to-end recovery from MinIO-stored physical backup."
