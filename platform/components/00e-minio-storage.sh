#!/usr/bin/env bash
# 00e — MinIO storage prep (StorageClass + target dir + static PV).
#
# Must run BEFORE 07a-minio.sh on a fresh install: the MinIO chart creates
# a PVC named `minio` via the Deployment's volume reference, and it needs
# to find the pre-created static PV to bind to (the minio-local SC is
# no-provisioner).
#
# Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

SC_SRC="$PLATFORM_DIR/manifests/k3s/storageclass-minio-local.yaml"
PV_SRC="$PLATFORM_DIR/manifests/minio/static-pv.yaml"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Sanity: /var/lib/minio must exist and be its own mountpoint
green "==> [1/4] verify /var/lib/minio is its own partition"
if [ "$EUID" -ne 0 ]; then
  red "    must run as root to verify mount + create target dirs"
  exit 1
fi
if ! mountpoint -q /var/lib/minio; then
  red "    /var/lib/minio is NOT a separate mountpoint"
  red "    Run 00-host-bootstrap.sh first to create the LVM partition + mount"
  exit 1
fi
df -h /var/lib/minio | tail -1

# 2. Create target dir with correct owner/perms
green "==> [2/4] ensure /var/lib/minio/data exists with correct uid/gid/mode"
# MinIO container runs UID 1000 = ops group; setgid 2777 so child files
# inherit gid 1000 (matches local-path-provisioner's default helper-pod
# behaviour the original PV was created with)
mkdir -p /var/lib/minio/data
chown 0:1000 /var/lib/minio/data
chmod 2777 /var/lib/minio/data
stat -c "    %n  %u:%g  mode=%a" /var/lib/minio/data

# 3. Apply the StorageClass
green "==> [3/4] apply minio-local StorageClass"
[ -f "$SC_SRC" ] || { red "ERROR: $SC_SRC not found"; exit 1; }
kubectl apply -f "$SC_SRC"

# 4. Apply the static PV (with claimRef pre-binding)
green "==> [4/4] apply static PV (pre-bound via claimRef)"
[ -f "$PV_SRC" ] || { red "ERROR: $PV_SRC not found"; exit 1; }
kubectl apply -f "$PV_SRC"

cat <<EOF

✓ MinIO storage prep complete.

  StorageClass: minio-local (no-provisioner, WaitForFirstConsumer, Retain)
  Static PV:
    minio-data-static  ->  /var/lib/minio/data  (200Gi)

The PV will go to status "Available" until the MinIO chart deploys and its
PVC (\`minio\` in the \`minio\` namespace) claims it. The PVC claimRef is
pre-set on the PV so binding is deterministic.

Next:
  bash 07a-minio.sh   # deploys the MinIO chart against this PV
EOF
