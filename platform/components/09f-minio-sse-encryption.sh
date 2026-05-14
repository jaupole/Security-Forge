#!/usr/bin/env bash
# 09f — MinIO bucket-level SSE-S3 encryption.
#
# Wires a 32-byte master key into MinIO via MINIO_KMS_SECRET_KEY env var,
# then sets bucket auto-encryption on `backups`. From that point on,
# every object MinIO writes (Velero kopia blobs, CNPG barman dumps,
# anything else) is AES-256-GCM encrypted at rest.
#
# Why bucket-level (not per-cluster):
#   - CNPG/barman has no client-side encryption hook (only AES256/aws:kms
#     server-side flags, which both require the bucket to support SSE).
#   - Velero kopia already client-side encrypts (since Track 1, 09e), but
#     bucket-level encryption is defense-in-depth: an attacker with raw
#     storage access (no MinIO creds) sees no plaintext metadata either.
#   - One config change, no per-consumer wiring.
#
# Trade-off: master key + MinIO root creds = decrypt. Same trust boundary
# as plaintext if a single compromised admin account has both — but the
# realistic threat (storage exfiltration without the running MinIO
# process to ask for keys) is closed.
#
# What this does (idempotent on OpenBao + chart side; one-shot on the
# bucket-encryption setting + existing-data rewrite):
#   1. Generates a strong 32-byte master key if not already in OpenBao.
#   2. Stashes at OpenBao secret/data/platform/minio/sse-master-key
#      with fields { key_name, master_key_b64 }.
#   3. Re-loads vso.hcl policy.
#   4. Creates OpenBao K8s auth role `minio-vso` bound to the `vso` policy.
#   5. Applies SA + VaultAuth in minio ns.
#   6. Applies the VSO binding rendering minio-kms-creds Secret.
#   7. Patches MinIO Deployment to load MINIO_KMS_SECRET_KEY via envFrom.
#   8. Waits for MinIO rollout.
#   9. Sets bucket auto-encryption: `mc encrypt set sse-s3 local/backups`.
#  10. Verifies with a test object (sse-encryption header present).
#  11. Triggers fresh CNPG Backup CRs to encrypt new copies.
#
# Pre-conditions:
#   - 07a-minio.sh complete (MinIO deployed, backups bucket exists).
#   - 09e-velero-rotate-passphrase.sh complete (clean kopia state).
#   - openbao-root-token-tmp Secret in openbao ns.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

NS_MINIO=minio
NS_BAO=openbao
POD_BAO=openbao-0
KEY_NAME=secforge-minio-key

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found."; exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1+2. Generate or reuse master key, stash in OpenBao.
green "==> check / generate MinIO SSE master key in OpenBao"
EXISTING=$(bao bao kv get -field=master_key_b64 secret/platform/minio/sse-master-key 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  yellow "    reusing existing master key from OpenBao"
else
  MASTER_KEY=$(head -c 32 /dev/urandom | base64)
  bao bao kv put secret/platform/minio/sse-master-key \
    key_name="$KEY_NAME" \
    master_key_b64="$MASTER_KEY" >/dev/null
  unset MASTER_KEY
  green "    generated 32-byte master key"
fi

# 3. Re-load vso policy
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 4. Create OpenBao K8s auth role `minio-vso`.
green "==> create / update OpenBao K8s auth role minio-vso"
bao bao write auth/kubernetes/role/minio-vso \
  bound_service_account_names=minio-vso \
  bound_service_account_namespaces="$NS_MINIO" \
  policies=vso \
  audience=https://kubernetes.default.svc.cluster.local \
  alias_name_source=serviceaccount_uid \
  ttl=1h max_ttl=24h >/dev/null
green "    role minio-vso bound to [vso]"

unset ROOT_TOKEN

# 5+6. Apply SA + VaultAuth + VSO binding.
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/minio/04-vault-auth.yaml"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/minio/05-sse-master-key-vso-binding.yaml"

# Wait for VSO to render the Secret.
green "==> waiting for VSO to render minio-kms-creds Secret (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS_MINIO" get secret minio-kms-creds >/dev/null 2>&1; then
    LEN=$(kubectl -n "$NS_MINIO" get secret minio-kms-creds -o jsonpath='{.data.MINIO_KMS_SECRET_KEY}' | base64 -d | wc -c)
    if [ "$LEN" -gt 40 ]; then
      green "    rendered after $((i*5))s"; break
    fi
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render minio-kms-creds within 60s"; exit 1
  fi
  sleep 5
done

# 7. Patch MinIO Deployment with envFrom.
# The chart's `environment` map doesn't support secret-sourced values, so
# we patch the Deployment directly. NOTE: a future `helm upgrade minio`
# WILL clobber this — re-run 09f after any chart upgrade.
green "==> patch MinIO Deployment with envFrom: minio-kms-creds"
CURRENT=$(kubectl -n "$NS_MINIO" get deploy minio -o json | jq -c '.spec.template.spec.containers[0].envFrom // []')
if echo "$CURRENT" | grep -q "minio-kms-creds"; then
  yellow "    envFrom already references minio-kms-creds"
else
  NEW_ENVFROM=$(echo "$CURRENT" | jq -c '. + [{"secretRef": {"name": "minio-kms-creds"}}]')
  kubectl -n "$NS_MINIO" patch deploy minio --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/envFrom\",\"value\":$NEW_ENVFROM}
  ]" 2>&1 | head -3
  yellow "    waiting for MinIO rollout"
  kubectl -n "$NS_MINIO" rollout status deploy/minio --timeout=180s
fi

# 8. Set bucket auto-encryption via mc.
green "==> configure mc client + set sse-s3 on backups bucket"
AK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
SK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)
kubectl -n "$NS_MINIO" exec deploy/minio -- mc alias set local http://localhost:9000 "$AK" "$SK" >/dev/null 2>&1
kubectl -n "$NS_MINIO" exec deploy/minio -- mc encrypt set sse-s3 local/backups 2>&1 | tail -3
kubectl -n "$NS_MINIO" exec deploy/minio -- mc encrypt info local/backups 2>&1 | tail -3
unset AK SK

# 9. Verify with a test PUT.
green "==> verify encryption with a test object"
kubectl -n "$NS_MINIO" exec deploy/minio -- sh -c 'echo "encrypt-verify-$(date +%s)" > /tmp/sse-test.txt; mc cp /tmp/sse-test.txt local/backups/sse-verify/sse-test.txt >/dev/null'
ENC=$(kubectl -n "$NS_MINIO" exec deploy/minio -- mc stat local/backups/sse-verify/sse-test.txt 2>&1 | grep -i 'encryption' || true)
if echo "$ENC" | grep -qiE 'SSE-S3|AES'; then
  green "    test object encrypted: $ENC"
  kubectl -n "$NS_MINIO" exec deploy/minio -- mc rm local/backups/sse-verify/sse-test.txt >/dev/null
else
  red "ERROR: test object NOT encrypted. Got: $ENC"
  exit 1
fi

# 10. Trigger fresh CNPG Backups so an encrypted copy lands in MinIO.
green "==> trigger fresh CNPG Backup for each cluster (encrypted copies)"
for NS_CLUSTER in keycloak spicedb; do
  CL=$(kubectl -n "$NS_CLUSTER" get cluster.postgresql.cnpg.io -o jsonpath='{.items[0].metadata.name}')
  BK_NAME="sse-rotation-${NS_CLUSTER}-$(date -u +%Y%m%d-%H%M%S)"
  green "    triggering Backup $BK_NAME for $NS_CLUSTER/$CL"
  cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BK_NAME
  namespace: $NS_CLUSTER
  labels:
    secforge.platform/purpose: sse-encryption-verify
spec:
  cluster:
    name: $CL
  method: barmanObjectStore
EOF
done

green "==> waiting for CNPG backups to complete (up to 5 min)"
for NS_CLUSTER in keycloak spicedb; do
  BK_NAME=$(kubectl -n "$NS_CLUSTER" get backup.postgresql.cnpg.io -l 'secforge.platform/purpose=sse-encryption-verify' --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
  for i in $(seq 1 60); do
    PHASE=$(kubectl -n "$NS_CLUSTER" get backup.postgresql.cnpg.io "$BK_NAME" -o jsonpath="{.status.phase}" 2>/dev/null || true)
    [ "$PHASE" = "completed" ] && break
    [ "$PHASE" = "failed" ] && { red "  $NS_CLUSTER/$BK_NAME Failed"; kubectl -n "$NS_CLUSTER" describe backup.postgresql.cnpg.io "$BK_NAME" | tail -10; break; }
    sleep 5
  done
  green "    $NS_CLUSTER/$BK_NAME phase=$PHASE"
done

# 11. Spot-check: a freshly-written CNPG backup file should show encryption.
green "==> spot-check encryption on a CNPG backup object"
AK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
SK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)
kubectl -n "$NS_MINIO" exec deploy/minio -- mc alias set local http://localhost:9000 "$AK" "$SK" >/dev/null 2>&1
NEWEST=$(kubectl -n "$NS_MINIO" exec deploy/minio -- mc find local/backups/cnpg/keycloak/ --newer-than 5m 2>&1 | head -1 || true)
if [ -n "$NEWEST" ]; then
  ENC=$(kubectl -n "$NS_MINIO" exec deploy/minio -- mc stat "$NEWEST" 2>&1 | grep -i 'encryption' || true)
  if echo "$ENC" | grep -qiE 'SSE-S3|AES'; then
    green "    newest CNPG file is encrypted: $NEWEST"
  else
    yellow "    WARN: newest CNPG file did NOT show encryption header: $NEWEST → $ENC"
  fi
else
  yellow "    no CNPG file newer than 5m found — re-check manually."
fi
unset AK SK

cat <<EOF

✓ MinIO SSE-S3 enabled on the backups bucket.

  Master key:        secret/data/platform/minio/sse-master-key (OpenBao)
                     fields: key_name, master_key_b64
                     rendered to K8s Secret minio/minio-kms-creds
  Bucket policy:     local/backups → auto sse-s3 on every PUT
  CNPG impact:       new physical backups + WAL encrypted at rest
  Velero impact:     kopia blobs (already client-encrypted) double-encrypted at storage layer
  Existing objects:  remain plaintext until naturally rewritten by retention.
                     To force-rewrite, run:
                       mc cp --recursive --remove --preserve local/backups/ local/backups/

Restore drill (next session):
  1. kubectl apply -f restore-secforge-keycloak-db.yaml
  2. Wait for verify-restore-keycloak ns to come up
  3. Confirm Keycloak realm data is intact
  4. Tear down

To rotate the master key in the future (BREAKS existing data — keep the
old key around long enough to re-encrypt existing objects first):
  bao kv put secret/platform/minio/sse-master-key \\
    key_name=<new-name> master_key_b64=<new-base64>
  kubectl -n minio rollout restart deploy/minio
  # Re-encrypt all existing objects under the new key:
  mc cp --recursive --remove --preserve local/backups/ local/backups/
EOF
