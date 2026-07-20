#!/usr/bin/env bash
# containerd-gc.sh — prune unreferenced container images from k3s containerd.
#
# WHY (infra-sweep opt-2): Renovate digest bumps leave every superseded
# image behind (15 stale proposal-forge digests alone ≈ 3.5G; store was
# ~50G/112 images). Kubelet's built-in image GC only fires at 85% disk on
# /var/lib/rancher — long after the accumulation is a restore/scan burden.
# A scheduled prune keeps the store tight without touching k3s config
# (changing kubelet GC thresholds would need a k3s restart — mount-storm
# risk, see docs/03-runbooks/k3s-encryption-reenable.md).
#
# `crictl rmi --prune` removes only images unreferenced by any pod/container,
# so anything running (or restartable from local state) is untouched; pinned
# digests re-pull from GHCR/quay on demand.
#
# Runs weekly as root from k3s-containerd-gc.timer. Exit 0 unless the prune
# itself fails.

set -uo pipefail

CRICTL="k3s crictl"
OUTDIR=/var/lib/node_exporter/textfile_collector
OUTFILE="$OUTDIR/secforge_containerd_gc.prom"

before_n=$($CRICTL images -q 2>/dev/null | wc -l)
before_kb=$(du -s /var/lib/rancher/agent/containerd 2>/dev/null | cut -f1)
[ -z "$before_kb" ] && before_kb=$(du -s /var/lib/rancher 2>/dev/null | cut -f1)

$CRICTL rmi --prune

after_n=$($CRICTL images -q 2>/dev/null | wc -l)
after_kb=$(du -s /var/lib/rancher/agent/containerd 2>/dev/null | cut -f1)
[ -z "$after_kb" ] && after_kb=$(du -s /var/lib/rancher 2>/dev/null | cut -f1)

echo "done: images ${before_n} -> ${after_n}, store $((before_kb/1024))MiB -> $((after_kb/1024))MiB (freed $(( (before_kb-after_kb)/1024 ))MiB)"

mkdir -p "$OUTDIR"
cat > "$OUTFILE.tmp" <<METRICS
# HELP secforge_containerd_images Images in the containerd store after the last GC run.
# TYPE secforge_containerd_images gauge
secforge_containerd_images $after_n
# HELP secforge_containerd_gc_last_run_timestamp_seconds Unix time of the last containerd GC run.
# TYPE secforge_containerd_gc_last_run_timestamp_seconds gauge
secforge_containerd_gc_last_run_timestamp_seconds $(date +%s)
METRICS
chmod 0644 "$OUTFILE.tmp"   # world-readable regardless of caller umask (node-exporter runs as nobody)
mv "$OUTFILE.tmp" "$OUTFILE"
