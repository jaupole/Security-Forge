#!/usr/bin/env bash
# 00d — Wazuh storage prep (StorageClass + target dirs + static PVs).
#
# Must run BEFORE 07-wazuh.sh on a fresh install: the wazuh chart creates
# PVCs via volumeClaimTemplates with the configured storageClassName, and
# they need to find pre-created static PVs to bind to (the wazuh-local SC
# is no-provisioner).
#
# Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

SC_SRC="$PLATFORM_DIR/manifests/k3s/storageclass-wazuh-local.yaml"
PV_SRC="$PLATFORM_DIR/manifests/wazuh/static-pvs.yaml"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Sanity: /var/lib/wazuh must exist and be its own mountpoint
green "==> [1/4] verify /var/lib/wazuh is its own partition"
if [ "$EUID" -ne 0 ]; then
  red "    must run as root to verify mount + create target dirs"
  exit 1
fi
if ! mountpoint -q /var/lib/wazuh; then
  red "    /var/lib/wazuh is NOT a separate mountpoint"
  red "    Run 00-host-bootstrap.sh first to create the LVM partition + mount"
  exit 1
fi
df -h /var/lib/wazuh | tail -1

# 2. Create target dirs with correct owner/perms
green "==> [2/4] ensure target dirs exist with correct uid/gid/mode"
# Manager: root:wazuh-gid-999, setgid 2777 (matches local-path-provisioner's
# default helper-pod behaviour so the wazuh-manager container's UID 999
# can write inheriting gid 999)
mkdir -p /var/lib/wazuh/wazuh-manager-data
chown 0:999 /var/lib/wazuh/wazuh-manager-data
chmod 2777 /var/lib/wazuh/wazuh-manager-data

# Indexer: ops:ops, setgid 2777 (mirrors default local-path-provisioner)
mkdir -p /var/lib/wazuh/wazuh-indexer-data
chown 1000:1000 /var/lib/wazuh/wazuh-indexer-data
chmod 2777 /var/lib/wazuh/wazuh-indexer-data

stat -c "    %n  %u:%g  mode=%a" \
    /var/lib/wazuh/wazuh-manager-data \
    /var/lib/wazuh/wazuh-indexer-data

# 3. Apply the StorageClass
green "==> [3/4] apply wazuh-local StorageClass"
[ -f "$SC_SRC" ] || { red "ERROR: $SC_SRC not found"; exit 1; }
kubectl apply -f "$SC_SRC"

# 4. Apply the static PVs (with claimRef pre-binding)
green "==> [4/4] apply static PVs (pre-bound via claimRef)"
[ -f "$PV_SRC" ] || { red "ERROR: $PV_SRC not found"; exit 1; }
kubectl apply -f "$PV_SRC"

cat <<EOF

✓ Wazuh storage prep complete.

  StorageClass: wazuh-local (no-provisioner, WaitForFirstConsumer, Retain)
  Static PVs:
    wazuh-manager-data-static  ->  /var/lib/wazuh/wazuh-manager-data  (50Gi)
    wazuh-indexer-data-static  ->  /var/lib/wazuh/wazuh-indexer-data  (30Gi)

These will go to status "Available" until the wazuh chart deploys and its
PVCs (wazuh-manager-data-wazuh-manager-0 + wazuh-indexer-data-wazuh-indexer-0)
claim them. The PVC claimRef is pre-set on each PV so binding is deterministic
even if multiple wazuh-local PVs ever existed.

Next:
  bash 07-wazuh.sh   # deploys the wazuh chart against these PVs
EOF
