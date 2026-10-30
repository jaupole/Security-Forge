#!/usr/bin/env bash
# Unwind stacked spiffe-workload-api CSI bind mounts (the "mount storm").
#
# Symptom (2026-05-09 and 2026-10-30): /proc/mounts grows to 100k+ lines, all
# tmpfs at .../volumes/kubernetes.io~csi/spiffe-workload-api/mount stacked up
# to the kernel's 16384-per-mountpoint cap. Feedback loop: huge mount table →
# spiffe-csi-driver's mount checks allocate until OOMKilled → kubelet retries
# every pending NodePublish → one more layer per retry. Node compute-starves
# (load 25+ with zero IO pressure); SSH hangs at auth while tailscale ping works.
# Trigger on 2026-10-30: two k3s restarts 6 min apart during the 1.31→1.33 step.
#
# This detaches every stacked CSI mount via umount2(MNT_DETACH) — NOT the
# umount(8) binary, which re-parses the 100k-line table on every call. Running
# containers hold their own mount namespace and are unaffected; kubelet
# re-mounts each path once, cleanly, as the pod starts. Expect mounts ≈ 500 after.
#
# Usage: sudo platform/scripts/csi-mount-unwind.sh [--dry-run]
set -euo pipefail
DRY=${1:-}
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
echo "before: $(wc -l < /proc/mounts) mounts, load $(cut -d' ' -f1-3 /proc/loadavg)"
python3 - "$DRY" <<'PY'
import ctypes, collections, sys
dry = sys.argv[1] == "--dry-run"
libc = ctypes.CDLL("libc.so.6", use_errno=True)
paths = collections.Counter(l.split()[1] for l in open("/proc/mounts") if "kubernetes.io~csi" in l)
for p, c in sorted(paths.items(), key=lambda kv: -kv[1]):
    if c < 2:
        continue
    if dry:
        print(f"{c:6d} stacked  {p}"); continue
    n = 0
    while libc.umount2(p.encode(), 2) == 0:   # MNT_DETACH
        n += 1
    print(f"{c:6d} stacked -> {n} detach call(s)  {p}")
PY
echo "after:  $(wc -l < /proc/mounts) mounts"
