#!/usr/bin/env bash
# 99 — One-shot cleanup script for the 24h soak after the 2026-05-14
# Wazuh + MinIO partition migrations.
#
# Scheduled via `at` to run at 2026-05-15 ~15:30 CEST.
# Output → /var/log/secforge/storage-soak-cleanup-2026-05-15.log
#
# Pre-flight safety checks (fail-closed): if ANY of these are not what we
# expect, the script aborts WITHOUT deleting anything and leaves the old
# Released PVs in place for manual investigation.
#
#   1. The three old PVs are present and in Released state
#   2. wazuh-manager-0, wazuh-indexer-0, wazuh-dashboard, minio pods are
#      all 1/1 Running with age >12h (no recent restart that might indicate
#      we needed to roll back)
#   3. mapper_parsing_exception count over the last hour is 0 (the
#      k3s-audit decoder + agent out_format fix is still effective)
#   4. The NEW static PVs (minio-data-static, wazuh-manager-data-static,
#      wazuh-indexer-data-static) are all Bound — confirming the new
#      storage is what's actually being used
#
# On success: deletes the 3 old PVs, recursively removes the on-disk
# data, reports the disk reclaim.
#
# Reference memory: project_wazuh_partition_migration.md

set -uo pipefail

OLD_MGR_PV=pvc-9dc5a320-290b-451c-929c-fc506c31fc45
OLD_IDX_PV=pvc-eb7f1641-4f32-433a-9a9b-963b49e496bb
OLD_MIN_PV=pvc-d5eb93e9-f0b7-4d7e-baa1-e97709a85ec2

LOG_DIR=/var/log/secforge
LOG_FILE=$LOG_DIR/storage-soak-cleanup-2026-05-15.log
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

log "==== storage soak cleanup BEGIN ===="
log "PVs to delete: $OLD_MGR_PV (wazuh-manager) / $OLD_IDX_PV (wazuh-indexer) / $OLD_MIN_PV (minio)"

# ----- Pre-flight 1: old PVs are present + Released -----
log ""
log "PREFLIGHT 1/4: old PVs are Released"
for pv in "$OLD_MGR_PV" "$OLD_IDX_PV" "$OLD_MIN_PV"; do
  phase=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" != "Released" ]]; then
    log "  ABORT: PV $pv is in phase '$phase' (expected 'Released'). Leaving everything in place."
    exit 1
  fi
  log "  $pv  phase=$phase  ✓"
done

# ----- Pre-flight 2: critical pods 1/1 Running with age >12h -----
log ""
log "PREFLIGHT 2/4: wazuh + minio pods Running >12h"
declare -A POD_CHECKS=(
  [wazuh/wazuh-manager-0]="" [wazuh/wazuh-indexer-0]=""
  [wazuh/-l_app.kubernetes.io/name=wazuh-dashboard]="" [minio/-l_app=minio]=""
)
check_pod() {
  local ns="$1" selector="$2" label="$3"
  local pod_name
  if [[ "$selector" == -l* ]]; then
    pod_name=$(kubectl -n "$ns" get pods "${selector//_/ }" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  else
    pod_name="$selector"
  fi
  [[ -z "$pod_name" ]] && { log "  ABORT: no pod found for $label"; return 1; }
  local ready phase start_ts now_ts age_s
  ready=$(kubectl -n "$ns" get pod "$pod_name" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  phase=$(kubectl -n "$ns" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  start_ts=$(kubectl -n "$ns" get pod "$pod_name" -o jsonpath='{.status.startTime}' 2>/dev/null || true)
  if [[ "$ready" != "true" || "$phase" != "Running" ]]; then
    log "  ABORT: $ns/$pod_name phase=$phase ready=$ready"
    return 1
  fi
  if [[ -z "$start_ts" ]]; then
    log "  ABORT: $ns/$pod_name has no startTime"
    return 1
  fi
  now_ts=$(date +%s)
  age_s=$(( now_ts - $(date -d "$start_ts" +%s) ))
  if (( age_s < 43200 )); then  # 12h
    log "  ABORT: $ns/$pod_name age=${age_s}s (<12h). A recent restart might mean rollback was needed."
    return 1
  fi
  log "  $ns/$pod_name  phase=Running ready=true age=$((age_s/3600))h  ✓"
  return 0
}
check_pod wazuh wazuh-manager-0 "wazuh-manager-0"                  || exit 1
check_pod wazuh wazuh-indexer-0 "wazuh-indexer-0"                  || exit 1
check_pod wazuh -l_app.kubernetes.io/name=wazuh-dashboard "wazuh-dashboard" || exit 1
check_pod minio -l_app=minio "minio"                                || exit 1

# ----- Pre-flight 3: indexer ingest healthy (mapper_parsing_exception = 0) -----
log ""
log "PREFLIGHT 3/4: indexer ingest healthy (mapper_parsing_exception count last 1h)"
count=$(kubectl -n wazuh logs wazuh-manager-0 --since=1h --tail=200000 2>/dev/null \
        | grep -cE "mapper_parsing_exception|field name cannot contain only the character" || true)
if (( count > 0 )); then
  log "  ABORT: mapper_parsing_exception count = $count in last 1h (expected 0). Indexer pipeline issue — investigate."
  exit 1
fi
log "  mapper_parsing_exception count = 0  ✓"

# ----- Pre-flight 4: new static PVs are Bound -----
log ""
log "PREFLIGHT 4/4: new static PVs are Bound"
for pv in minio-data-static wazuh-manager-data-static wazuh-indexer-data-static; do
  phase=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" != "Bound" ]]; then
    log "  ABORT: PV $pv is in phase '$phase' (expected 'Bound'). New storage isn't fully active."
    exit 1
  fi
  log "  $pv  phase=$phase  ✓"
done

# ----- Snapshot before-state for the log -----
log ""
log "DISK BEFORE cleanup:"
df -h /var/lib/rancher /var/lib/wazuh /var/lib/minio | tee -a "$LOG_FILE"

# ----- Execute cleanup -----
log ""
log "EXECUTING cleanup..."

log "  deleting PVs..."
kubectl delete pv "$OLD_MGR_PV" "$OLD_IDX_PV" "$OLD_MIN_PV"

log "  removing on-disk data on rancher partition..."
for d in \
  "/var/lib/rancher/k3s/storage/${OLD_MGR_PV}_wazuh_wazuh-manager-data-wazuh-manager-0" \
  "/var/lib/rancher/k3s/storage/${OLD_IDX_PV}_wazuh_wazuh-indexer-data-wazuh-indexer-0" \
  "/var/lib/rancher/k3s/storage/${OLD_MIN_PV}_minio_minio"
do
  if [[ -d "$d" ]]; then
    log "    rm -rf $d"
    rm -rf "$d"
  else
    log "    skip (not found): $d"
  fi
done

# ----- Snapshot after-state -----
log ""
log "DISK AFTER cleanup:"
df -h /var/lib/rancher /var/lib/wazuh /var/lib/minio | tee -a "$LOG_FILE"

log ""
log "==== storage soak cleanup COMPLETE ===="
