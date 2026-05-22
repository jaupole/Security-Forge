#!/usr/bin/env bash
# 09e — Rotate Velero kopia repository passphrase from chart-default
# `static-passw0rd` to a strong value stored in OpenBao.
#
# What this does (idempotent on the OpenBao side; one-shot for the
# Velero-side cutover — re-running deletes BackupRepositories AGAIN):
#   1. Generates a strong passphrase if not already in OpenBao.
#   2. Stashes at OpenBao secret/data/platform/velero/kopia-passphrase.
#   3. Re-loads vso.hcl policy.
#   4. Applies VSO binding rendering velero-repo-credentials-vso.
#   5. Updates Velero Deployment to use the VSO-rendered Secret name.
#   6. Deletes all existing BackupRepository CRs (they're encrypted with
#      the old default passphrase and can't be re-opened).
#   7. Triggers a fresh backup to confirm new repos are created with the
#      new passphrase.
#
# Trade-off: existing PV backups (kopia-encrypted) become UNREADABLE
# after rotation. Cost is one day of PV backup history (the daily
# scheduled backup will recreate everything within 24h). K8s resource
# backups are NOT affected — those aren't kopia-encrypted.
#
# Pre-conditions:
#   - 09a-velero.sh complete (Velero deployed, BackupRepositories exist).
#   - openbao-root-token-tmp Secret in openbao ns.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

NS=velero
NS_BAO=openbao
POD_BAO=openbao-0

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

# 1+2. Generate or reuse passphrase, stash in OpenBao
green "==> check / generate kopia passphrase in OpenBao"
EXISTING=$(bao bao kv get -field=passphrase secret/platform/velero/kopia-passphrase 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  yellow "    reusing existing passphrase from OpenBao"
else
  PP=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 64)
  bao bao kv put secret/platform/velero/kopia-passphrase passphrase="$PP" >/dev/null
  unset PP
  green "    generated 64-char strong passphrase"
fi

# 3. Re-load vso policy
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

unset ROOT_TOKEN

# 4. Replace the chart-managed velero-repo-credentials Secret with a
#    VSO-rendered one. Velero v1.10+ has no flag to override the Secret
#    name — it hardcodes `velero-repo-credentials`. So we delete the
#    static-passw0rd one and let VSO recreate it.

# 4a. Strip stale --repo-credentials-secret-name arg if a previous
# (broken) run added it. Velero v1.15.1 rejects this unknown flag.
green "==> strip any stale --repo-credentials-secret-name arg from velero deploy"
CURRENT_ARGS=$(kubectl -n "$NS" get deploy velero -o json | jq -c '.spec.template.spec.containers[0].args')
if echo "$CURRENT_ARGS" | grep -q "repo-credentials-secret-name"; then
  CLEAN_ARGS=$(echo "$CURRENT_ARGS" | jq -c '[.[] | select(test("repo-credentials-secret-name") | not)]')
  kubectl -n "$NS" patch deploy velero --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$CLEAN_ARGS}
  ]"
  yellow "    stripped stale flag"
fi

# 4b. Tear down the stale -vso side-binding from the broken first run, if any.
kubectl -n "$NS" delete vaultstaticsecret velero-repo-credentials-vso --ignore-not-found
kubectl -n "$NS" delete secret velero-repo-credentials-vso --ignore-not-found

# 4c. Delete the chart-managed Secret (static-passw0rd) so VSO can take
# over the canonical name.
green "==> delete chart-managed velero-repo-credentials Secret (static-passw0rd)"
kubectl -n "$NS" delete secret velero-repo-credentials --ignore-not-found

# 4d. Apply VSO binding (uses existing velero-vso K8s auth role).
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/velero/05-kopia-passphrase-vso-binding.yaml"

# Wait for VSO to render the canonical Secret.
green "==> waiting for VSO to render velero-repo-credentials (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret velero-repo-credentials >/dev/null 2>&1; then
    PW_LEN=$(kubectl -n "$NS" get secret velero-repo-credentials -o jsonpath='{.data.repository-password}' | base64 -d | wc -c)
    if [ "$PW_LEN" -gt 32 ]; then
      green "    rendered after $((i*5))s (passphrase length: $PW_LEN)"; break
    fi
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render strong velero-repo-credentials within 60s"; exit 1
  fi
  sleep 5
done

# 5. Restart Velero so it loads the new password from the recreated Secret.
green "==> restart Velero deployment to pick up new passphrase"
kubectl -n "$NS" rollout restart deploy/velero
kubectl -n "$NS" rollout status deploy/velero --timeout=120s

# 6. Delete BackupRepository CRs AND wipe the kopia/ prefix in MinIO.
# The CRs are just K8s pointers; the actual encrypted format blocks live
# in the object store (s3://backups/velero/kopia/<ns>/kopia.repository
# + format manager blobs). If we leave them, kopia tries to OPEN existing
# repos with the new passphrase and fails with "invalid repository
# password" → BackupRepository stuck NotReady.
green "==> delete existing BackupRepository CRs"
kubectl -n "$NS" delete backuprepository --all 2>&1 | tail -5

green "==> wipe kopia/ prefix in MinIO (old passphrase encrypted blobs are useless)"
NS_MINIO=minio
MINIO_POD_DEPLOY=deploy/minio
AK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)
SK=$(kubectl -n "$NS_MINIO" get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)
kubectl -n "$NS_MINIO" exec "$MINIO_POD_DEPLOY" -- mc alias set local http://localhost:9000 "$AK" "$SK" >/dev/null 2>&1
kubectl -n "$NS_MINIO" exec "$MINIO_POD_DEPLOY" -- mc rm --recursive --force local/backups/velero/kopia/ 2>&1 | tail -3
unset AK SK

# 7. Trigger an immediate backup to verify the new passphrase is in use.
BK_NAME="passphrase-rotation-verify-$(date -u +%Y%m%d-%H%M%S)"
green "==> trigger verification backup: $BK_NAME (small scope, fast)"
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $BK_NAME
  namespace: $NS
  labels:
    secforge.platform/purpose: passphrase-rotation-verify
spec:
  includedNamespaces: [keycloak]
  includeClusterResources: false
  snapshotVolumes: false
  defaultVolumesToFsBackup: false
  ttl: 24h0m0s
EOF

green "==> waiting for verification backup to complete (up to 2 min)"
for i in $(seq 1 24); do
  PHASE=$(kubectl -n "$NS" get backup.velero.io "$BK_NAME" -o jsonpath="{.status.phase}" 2>/dev/null || true)
  [ "$PHASE" = "Completed" ] && break
  [ "$PHASE" = "Failed" ] && { red "verification backup Failed"; kubectl -n "$NS" describe backup.velero.io "$BK_NAME" | tail -10; exit 1; }
  sleep 5
done

if [ "$PHASE" = "Completed" ]; then
  green "    verification backup Completed"
  kubectl -n "$NS" delete backup.velero.io "$BK_NAME"
fi

cat <<EOF

✓ Velero kopia passphrase rotated.

  Old passphrase: static-passw0rd  (chart default — now obsolete)
  New passphrase: 64-char random,  in OpenBao at secret/data/platform/velero/kopia-passphrase
                                   rendered to K8s Secret velero/velero-repo-credentials
                                   (the canonical name Velero hardcodes)

  All previous PV backups (kopia-encrypted with old passphrase): UNREADABLE.
  K8s resource backups (not kopia-encrypted): unaffected.

  The next scheduled daily-everything backup (02:00 UTC) will create
  fresh PV backups with the new passphrase, fully restoring backup
  coverage within 24h.

To rotate again in the future:
  bao kv put secret/platform/velero/kopia-passphrase passphrase=<new>
  kubectl -n velero delete backuprepository --all
  kubectl -n velero rollout restart deploy/velero
EOF
