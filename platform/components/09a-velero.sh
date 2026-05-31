#!/usr/bin/env bash
# 09a — Velero K8s + PV backups to MinIO `backups` bucket (prefix `velero/`).
#
# Order of operations (idempotent):
#   1. Apply velero namespace.
#   2. Provision (or reuse) MinIO user `velero-user` with prefix-scoped policy
#      on backups/velero/* in the `backups` bucket.
#   3. Stage access keys at OpenBao secret/data/minio/velero/credentials.
#   4. Re-load vso.hcl policy (already includes minio/velero path).
#   5. Apply VSO binding (renders K8s Secret velero-minio-credentials with
#      AWS-credentials INI shape).
#   6. Create OpenBao K8s auth role velero-vso.
#   7. Wait for VSO render.
#   8. Helm install Velero.
#   9. Apply ScheduledBackup CRs.
#   10. Trigger an initial on-demand backup to confirm pipeline works.
#
# Pre-conditions:
#   - 07a-minio.sh complete (MinIO + `backups` bucket).
#   - openbao-root-token-tmp Secret in openbao ns.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

CHART_VER="${VELERO_CHART_VER:-12.0.1}"
NS=velero
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

# 1. Namespace
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/velero/01-namespace.yaml"

# 2. Provision (or reuse) Velero MinIO user
green "==> provision MinIO user velero-user (scoped to backups/velero/*)"

EXISTING_AK=$(bao bao kv get -field=access_key secret/minio/velero/credentials 2>/dev/null || true)
EXISTING_SK=$(bao bao kv get -field=secret_key secret/minio/velero/credentials 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
  yellow "    reusing existing keys from OpenBao"
  VELERO_AK="$EXISTING_AK"; VELERO_SK="$EXISTING_SK"
else
  VELERO_AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
  VELERO_SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  green "    generated new keys"
fi

# Velero needs to write/read/list under the `velero/` prefix of the
# `backups` bucket. We don't grant other-prefix access (CNPG uses `cnpg/`).
# NOTE: no `s3:prefix` Condition. MinIO rejects it on
# `s3:GetBucketLocation` (which doesn't accept prefix conditions). The
# Object-level Resource ARN already scopes effective writes/reads to
# `backups/velero/*`; the bucket-level actions just expose bucket
# metadata, which is fine to share with cnpg-user (also a tenant).
POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::backups/velero/*"]
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

green "==> mc admin user add + policy attach (in MinIO pod)"
kubectl exec -n "$NS_MINIO" "$MINIO_POD" -- sh -c "
set -eu
export MC_CONFIG_DIR=/tmp/.mc-velero-provision
mkdir -p \$MC_CONFIG_DIR
mc alias set local http://localhost:9000 '${ROOT_USER}' '${ROOT_PASS}' >/dev/null
mc admin user add local '${VELERO_AK}' '${VELERO_SK}' 2>&1 | tail -1 || true
cat > /tmp/velero-policy.json <<'PJSON'
${POLICY_JSON}
PJSON
# `mc admin policy update` is deprecated in newer mc; create handles
# both create and overwrite when given a file. Suppress create's error
# if the policy already exists (idempotent path).
mc admin policy create local velero-policy /tmp/velero-policy.json 2>&1 || true
mc admin policy attach local velero-policy --user '${VELERO_AK}' 2>/dev/null || true
rm -f /tmp/velero-policy.json
rm -rf \$MC_CONFIG_DIR
echo 'velero MinIO user provisioned and policy attached'
" 2>&1 | tail -5

unset ROOT_USER ROOT_PASS

# 3. Stage creds
green "==> stage velero credentials at secret/minio/velero/credentials"
bao bao kv put secret/minio/velero/credentials \
    access_key="$VELERO_AK" \
    secret_key="$VELERO_SK" >/dev/null
unset VELERO_AK VELERO_SK

# 4. Re-load vso policy
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 5. Apply VSO binding
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/velero/02-vso-binding.yaml"

# 6. K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: velero-vso"
bao bao write auth/kubernetes/role/velero-vso \
  bound_service_account_names="velero-vso" \
  bound_service_account_namespaces="velero" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 7. Wait for VSO render
green "==> waiting for VSO to render velero-minio-credentials (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret velero-minio-credentials >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render velero-minio-credentials within 60s"; exit 1
  fi
  sleep 5
done

# 8. Helm install
# Chart 12+ renders the velero-repo-maintenance ConfigMap from
# `configuration.repositoryMaintenanceJob.repositoryConfigData` in values.yaml
# (chart-managed; don't pre-apply externally — Helm ownership check would reject).
"$LIB/install-helm.sh" \
  --release velero --namespace "$NS" \
  --repo-name vmware-tanzu --repo-url https://vmware-tanzu.github.io/helm-charts \
  --chart vmware-tanzu/velero --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/velero.yaml"

# 8b. Least-privilege RBAC (audit H-4.12) — applied AFTER Helm on purpose.
# values.yaml sets rbac.clusterAdministrator:false, so the chart renders no
# ClusterRoleBinding and the Helm upgrade above first PRUNES any pre-existing
# chart-managed `velero-server -> cluster-admin` binding (a delete, so the
# immutable roleRef is not an obstacle). This manifest then (re)creates the
# operator-owned scoped ClusterRole + binding. On a cluster still on the old
# cluster-admin binding, this is the one-time migration; see
# docs/03-runbooks/velero-restore-drill-leastpriv.md for the migration ordering,
# the 02:00/03:00 UTC backup-window timing constraint, and the restore-drill
# gate that must pass (Errors: 0) before H-4.12 is closed.
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/velero/07-rbac-leastprivilege.yaml"

# 9. ScheduledBackup CRs
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/velero/03-schedules.yaml"

# 10. Trigger an immediate on-demand backup so we can verify the pipeline.
green "==> triggering initial on-demand backup (will block until BSL is Available)"
for i in $(seq 1 12); do
  STATUS=$(kubectl -n "$NS" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$STATUS" = "Available" ]; then
    green "    BackupStorageLocation Available after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: BackupStorageLocation still not Available after 60s"
    kubectl -n "$NS" describe backupstoragelocation default | tail -20
    exit 1
  fi
  sleep 5
done

INITIAL_BACKUP="initial-$(date -u +%Y%m%d-%H%M%S)"
kubectl create -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $INITIAL_BACKUP
  namespace: $NS
  labels:
    secforge.platform/component: velero
    secforge.platform/purpose: bootstrap-verification
spec:
  excludedNamespaces: [kube-system, kube-public, kube-node-lease, default]
  includeClusterResources: true
  snapshotVolumes: false
  defaultVolumesToFsBackup: true
  ttl: 168h0m0s
EOF

echo
green "✓ Velero deployed."
echo
echo "Sanity:"
echo "  kubectl -n $NS get pods,backupstoragelocation,schedule"
echo "  kubectl -n $NS get backup $INITIAL_BACKUP -w   # tail until Phase=Completed"
echo
echo "Inspect backup contents in MinIO:"
echo "  kubectl -n minio port-forward svc/minio-console 9001:9001 &"
echo "  open http://localhost:9001 → log in with minio-root-credentials → bucket: backups → prefix velero/"
