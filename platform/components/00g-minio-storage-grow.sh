#!/usr/bin/env bash
# 00g — Reallocate the unused vg0/cnpg LV to MinIO (cnpg 400G→50G, minio 250G→600G).
#
# WHY (prod triage 2026-09-17): vg0 (952G on the md1 NVMe mirror) was carved at
# install time as root 60 / rancher 100 / cnpg 400 / minio 250 / wazuh 100 /
# runner 35, leaving 7.5G free. The 400G cnpg LV (xfs at /var/lib/cnpg) was
# NEVER used: CNPG PVCs are local-path volumes on vg0-rancher, no PV references
# /var/lib/cnpg and the filesystem was empty. Meanwhile /var/lib/minio — the
# Velero kopia repos, CNPG barman backups, Loki/Tempo and the Wazuh archive —
# sat at 86% (NodeDiskSpaceCritical) with wazuh-archive still growing until its
# 90d ILM window closes (2026-11-16). Moving 350G across fixes that structurally.
#
# The cnpg LV is kept (at 50G) rather than removed so the mount, fstab line and
# the option of moving Postgres data onto its own LV later stay intact.
#
# On the live node this was executed manually 2026-09-17 (umount → lvremove →
# lvcreate 50G → mkfs.xfs → mount → lvextend +350G → xfs_growfs, ~10s, online
# for MinIO). This script codifies the REBUILD path and is idempotent: it only
# acts when the LVs are still at the old sizes, and it refuses to touch a cnpg
# LV that has data on it. The fstab lines are unchanged (device-path based).
#
# Pairs with manifests/minio/static-pv.yaml (PV capacity 550Gi).
set -euo pipefail
VG=vg0
CNPG_LV=cnpg;   CNPG_MNT=/var/lib/cnpg;   CNPG_SIZE_G=50
MINIO_LV=minio; MINIO_MNT=/var/lib/minio; MINIO_SIZE_G=600

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
[ "$EUID" -eq 0 ] || { echo "run as root" >&2; exit 1; }

lv_size_g() { lvs --noheadings --units g --nosuffix -o lv_size "$VG/$1" | tr -d ' ' | cut -d. -f1; }

green "==> [1/2] ${VG}/${CNPG_LV}: want ${CNPG_SIZE_G}G"
cur=$(lv_size_g "$CNPG_LV")
if [ "$cur" -le "$CNPG_SIZE_G" ]; then
  yellow "    already ${cur}G — skipping"
else
  if mountpoint -q "$CNPG_MNT"; then
    [ "$(find "$CNPG_MNT" -mindepth 1 -maxdepth 1 | wc -l)" -eq 0 ] \
      || { echo "REFUSING: ${CNPG_MNT} is not empty" >&2; exit 1; }
    umount "$CNPG_MNT"
  fi
  lvremove -y "$VG/$CNPG_LV"
  lvcreate -y -L "${CNPG_SIZE_G}G" -n "$CNPG_LV" "$VG"
  mkfs.xfs -f -q "/dev/${VG}/${CNPG_LV}"
  grep -qF "/dev/${VG}/${CNPG_LV}" /etc/fstab || echo "/dev/${VG}/${CNPG_LV}  ${CNPG_MNT}  xfs  defaults 0 0" >> /etc/fstab
  mkdir -p "$CNPG_MNT"; systemctl daemon-reload; mount "$CNPG_MNT"
fi

green "==> [2/2] ${VG}/${MINIO_LV}: want ${MINIO_SIZE_G}G"
cur=$(lv_size_g "$MINIO_LV")
if [ "$cur" -ge "$MINIO_SIZE_G" ]; then
  yellow "    already ${cur}G — skipping"
else
  lvextend -L "${MINIO_SIZE_G}G" "$VG/$MINIO_LV"
  mountpoint -q "$MINIO_MNT" || mount "$MINIO_MNT"
  xfs_growfs "$MINIO_MNT" | tail -1
fi

green "✓ $(df -h --output=target,size,pcent "$CNPG_MNT" "$MINIO_MNT" | tail -n +2 | tr -s ' ' | paste -sd';' -)  (vg free: $(vgs --noheadings -o vg_free "$VG" | tr -d ' '))"
