#!/usr/bin/env bash
# Phase 8a.3 — provision a scoped MinIO user for Teleport session
# recording, persist creds in OpenBao, and rely on the VSO binding
# (01-vso-binding.yaml) to render the K8s Secret in `teleport` ns.
#
# Mirrors infrastructure/observability/apply-loki.sh §2-3 for the
# scoped-MinIO-user pattern. The bucket `teleport-recordings` already
# exists (provisioned by infrastructure/minio/bucket-bootstrap-job.yaml
# with versioning + GOVERNANCE Object Lock @ 90d).
#
# Pre-conditions:
#   - infrastructure/openbao/policies/vso.hcl extended (adds
#     secret/data/{teleport/oidc,minio/teleport/credentials})
#     and re-loaded.
#   - infrastructure/vault-secrets-operator/configure-openbao-role.sh
#     adds `teleport-vso` K8s auth role and re-run.
#   - infrastructure/teleport/01-vso-binding.yaml applied.
#   - BAO_TOKEN exported (admin-tier).
#
# Idempotent: re-runs reuse the existing creds if already in OpenBao,
# otherwise generate new ones.

set -euo pipefail

NS_TP=teleport
SECRET_NAME=teleport-minio-vso
USER_TAG=teleport-sessions
BUCKET=teleport-recordings
OPENBAO_PATH=secret/minio/teleport/credentials

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -z "${BAO_TOKEN:-}" ] && { red "BAO_TOKEN env var required"; exit 1; }

# 1. Reuse existing creds if present, else generate.
EXISTING_AK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=access_key "$OPENBAO_PATH" 2>/dev/null || true)
EXISTING_SK=$(kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv get -field=secret_key "$OPENBAO_PATH" 2>/dev/null || true)

if [ -n "$EXISTING_AK" ] && [ -n "$EXISTING_SK" ]; then
    yellow "==> reusing existing keys from OpenBao"
    AK="$EXISTING_AK"
    SK="$EXISTING_SK"
else
    green "==> generating new MinIO user keys"
    AK=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    SK=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
fi

# 2. Build scoped policy: read/write objects in teleport-recordings only.
#    GOVERNANCE Object Lock allows admin-bypass via PutObjectRetention,
#    which Teleport doesn't need; we exclude it from the policy so a
#    compromised teleport-sessions user cannot remove retention from
#    its own recordings.
POLICY_JSON=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:GetObjectRetention",
        "s3:PutObjectLegalHold"
      ],
      "Resource": ["arn:aws:s3:::teleport-recordings/*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketObjectLockConfiguration"
      ],
      "Resource": ["arn:aws:s3:::teleport-recordings"]
    }
  ]
}
EOF
)

# 3. Apply via mc inside the running MinIO pod.
#    The policy JSON contains double-quotes that conflict with bash's
#    `sh -c "..."` outer quoting. Stage the policy file via `kubectl
#    exec -i` (stdin pipe) instead — clean, no quoting puzzles.
green "==> mc admin user add + policy attach"
ROOT_USER=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
ROOT_PASS=$(kubectl get secret -n minio minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)
# MinIO chart's selector varies across releases — try modern label
# first, fall back to legacy. `if`/`then` form is set-e-safe (the
# `[ -z "$X" ] && ...` chain returns exit 1 when X is non-empty,
# which set -e would treat as script failure).
MINIO_POD=$(kubectl get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$MINIO_POD" ]; then
    MINIO_POD=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [ -z "$MINIO_POD" ]; then
    red "no MinIO pod found"
    exit 1
fi

# Stage policy file in the pod first (stdin pipe — no quoting issues).
kubectl exec -i -n minio "$MINIO_POD" -- \
    sh -c 'cat > /tmp/teleport-sessions-policy.json' <<<"$POLICY_JSON"

# Then run the mc admin commands (no embedded JSON).
kubectl exec -n minio "$MINIO_POD" -- env \
    AK="$AK" SK="$SK" ROOT_USER="$ROOT_USER" ROOT_PASS="$ROOT_PASS" \
    sh -c '
set -eu
export MC_CONFIG_DIR=/tmp/.mc-teleport-provision
mkdir -p $MC_CONFIG_DIR
mc alias set local http://localhost:9000 "$ROOT_USER" "$ROOT_PASS" >/dev/null
mc admin user add local "$AK" "$SK" 2>&1 | tail -1
mc admin policy create local teleport-sessions-policy /tmp/teleport-sessions-policy.json 2>/dev/null || \
    mc admin policy update local teleport-sessions-policy /tmp/teleport-sessions-policy.json 2>&1 | tail -1
mc admin policy attach local teleport-sessions-policy --user "$AK" 2>&1 | tail -1 || true
rm -f /tmp/teleport-sessions-policy.json
rm -rf $MC_CONFIG_DIR
echo "==> teleport-sessions MinIO user provisioned"
' 2>&1 | tail -8

# 4. Stage creds in OpenBao.
green "==> stage credentials at OpenBao path $OPENBAO_PATH"
kubectl exec -n openbao openbao-0 -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao kv put "$OPENBAO_PATH" \
        access_key="$AK" \
        secret_key="$SK" \
        bucket="$BUCKET" \
        endpoint="minio.minio.svc.cluster.local:9000" >/dev/null

unset AK SK

green ""
green "Phase 8a.3 — Teleport MinIO user provisioned + creds staged."
green ""
green "Verify VSO has rendered the K8s Secret:"
green "  kubectl get secret -n $NS_TP $SECRET_NAME"
green ""
