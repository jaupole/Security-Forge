#!/usr/bin/env bash
# Expose GitHub Actions self-hosted runner health to node-exporter textfile
# collector. Run every 60s via systemd timer (see gha-runner-exporter.timer).
#
# Outputs to /var/lib/node_exporter/textfile_collector/gha_runner.prom
# Metrics consumed by the secforge-gha-runners PrometheusRule group.
#
# Why this exists (2026-07-25 incident): runner-cleanup.sh deleted the live
# versioned bin/externals dirs after the v2.336.0 self-update switched the
# layout to symlinks. 5 runners crash-looped through ~14,000 restarts over
# 2.5 days with no page — nothing watched systemd unit state or restart
# counters on the host. A 6th runner kept running on deleted inodes (dangling
# bin symlink) and would have died on its next restart, which is why
# listener_ok checks the on-disk binary independently of unit state.

set -euo pipefail

RUNNER_BASE=/opt/github-runner/runners
OUTDIR=/var/lib/node_exporter/textfile_collector
OUTFILE="$OUTDIR/gha_runner.prom"
TMPFILE="$OUTFILE.tmp"

mkdir -p "$OUTDIR"

{
  cat <<'EOF'
# HELP secforge_gha_runner_unit_active GHA runner systemd unit is active (1) or not (0; includes activating/auto-restart crash loops).
# TYPE secforge_gha_runner_unit_active gauge
# HELP secforge_gha_runner_unit_restarts Systemd NRestarts for the runner unit (auto-restart count since last clean start).
# TYPE secforge_gha_runner_unit_restarts counter
# HELP secforge_gha_runner_listener_ok Runner.Listener binary resolvable and executable on disk (0 = dangling bin symlink; unit may still run on deleted inodes).
# TYPE secforge_gha_runner_listener_ok gauge
EOF

  for unit in $(systemctl list-unit-files --no-legend 'actions.runner.*.service' | awk '{print $1}'); do
    name=${unit#actions.runner.}
    name=${name%.service}

    active=0
    [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]] && active=1

    restarts=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || echo 0)

    listener_ok=0
    [[ -x "$RUNNER_BASE/$name/bin/Runner.Listener" ]] && listener_ok=1

    printf 'secforge_gha_runner_unit_active{runner="%s"} %d\n' "$name" "$active"
    printf 'secforge_gha_runner_unit_restarts{runner="%s"} %d\n' "$name" "$restarts"
    printf 'secforge_gha_runner_listener_ok{runner="%s"} %d\n' "$name" "$listener_ok"
  done

  cat <<EOF
# HELP secforge_gha_runner_exporter_last_run_timestamp_seconds Unix time this exporter last completed.
# TYPE secforge_gha_runner_exporter_last_run_timestamp_seconds gauge
secforge_gha_runner_exporter_last_run_timestamp_seconds $(date +%s)
EOF
} > "$TMPFILE"

chmod 0644 "$TMPFILE"   # world-readable regardless of caller umask (node-exporter runs as nobody)
mv "$TMPFILE" "$OUTFILE"
