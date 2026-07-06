#!/usr/bin/env bash
# 00f — GitHub Actions runner storage prep (dedicated LV at /opt/github-runner).
#
# WHY (infra-sweep debug-2): the runner workspace (~25G, ±multi-GB swings per
# CI build) lived on the 60G root LV alongside /var/log and kubelet's nodefs —
# a heavy build filling root would hit kubelet eviction and OS breakage. Every
# other heavy tenant (minio/cnpg/rancher/wazuh) already has its own LV; this
# gives the runner the same isolation (35G, xfs, mirrors the fstab pattern).
# It also caps runner growth: a runaway workspace now ENOSPCs the runner, not
# the node. (The 2026-07-06 gotenberg-build trivy ENOSPC was the tmpfs /tmp —
# fixed separately via TMPDIR=runner.temp in the workflows.)
#
# On the live node this was executed manually 2026-07-06 (stop runners →
# lvcreate/mkfs → rsync → fstab + mount swap → restart). This script codifies
# the REBUILD path: fresh node, run before installing the runners.
#
# Idempotent: skips creation if the LV exists / fstab entry present / mounted.

set -euo pipefail

LV=runner
VG=vg0
SIZE=35G
MNT=/opt/github-runner
FSTAB_LINE="/dev/${VG}/${LV}  ${MNT}  xfs  defaults 0 0"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ "$EUID" -eq 0 ] || { echo "run as root" >&2; exit 1; }

green "==> [1/3] LV ${VG}/${LV} (${SIZE})"
if lvs "${VG}/${LV}" >/dev/null 2>&1; then
  yellow "    exists — skipping create"
else
  lvcreate -L "$SIZE" -n "$LV" "$VG"
  mkfs.xfs "/dev/${VG}/${LV}"
fi

green "==> [2/3] fstab + mount at ${MNT}"
mkdir -p "$MNT"
grep -qF "/dev/${VG}/${LV}" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
mountpoint -q "$MNT" || { systemctl daemon-reload; mount "$MNT"; }

green "==> [3/3] ownership"
# uid/gid of the github-runner account (created by the runner install docs;
# tolerate a fresh node where it does not exist yet).
if id github-runner >/dev/null 2>&1; then
  chown github-runner:github-runner "$MNT"
fi

green "✓ runner storage ready at ${MNT} ($(df -h --output=size "$MNT" | tail -1 | tr -d ' '))"
