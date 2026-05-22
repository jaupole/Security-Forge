#!/usr/bin/env bash
# Expose kernel mount table utilization to node-exporter textfile collector.
# Run every 60s via systemd timer (see mount-count-exporter.timer).
#
# Outputs to /var/lib/node_exporter/textfile_collector/mount_count.prom
# Metrics consumed by PrometheusRule NodeMountTableSaturation alert.

set -euo pipefail

OUTDIR=/var/lib/node_exporter/textfile_collector
OUTFILE="$OUTDIR/mount_count.prom"
TMPFILE="$OUTFILE.tmp"

mkdir -p "$OUTDIR"

CURRENT=$(wc -l < /proc/mounts)
LIMIT=$(sysctl -n fs.mount-max)

cat > "$TMPFILE" <<EOF
# HELP node_mount_count Current number of kernel mount table entries.
# TYPE node_mount_count gauge
node_mount_count $CURRENT
# HELP node_mount_max_limit Kernel mount table maximum (fs.mount-max).
# TYPE node_mount_max_limit gauge
node_mount_max_limit $LIMIT
EOF

mv "$TMPFILE" "$OUTFILE"
