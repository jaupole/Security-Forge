#!/usr/bin/env bash
# Expose NVMe SMART health to the node-exporter textfile collector.
# Run every 5 min via systemd timer (see smart-exporter.timer).
#
# Outputs to /var/lib/node_exporter/textfile_collector/smart.prom
# Metrics consumed by the PrometheusRule node-resource-health group
# (NvmeSmartDegraded / NvmeSpareLow / NvmeMediaErrors / NvmeTemperatureHigh /
# NvmeSmartExporterStale). Until 2026-10-30 smartd only wrote to
# /var/log/smart-alerts.log — both drives sat past 100% rated wear with
# SMART FAILED for months and nothing paged.

set -euo pipefail

OUTDIR=/var/lib/node_exporter/textfile_collector
OUTFILE="$OUTDIR/smart.prom"
TMPFILE="$OUTFILE.tmp"

mkdir -p "$OUTDIR"

{
  cat <<'HDR'
# HELP secforge_nvme_smart_passed 1 if smartctl overall health self-assessment PASSED, else 0.
# TYPE secforge_nvme_smart_passed gauge
# HELP secforge_nvme_critical_warning NVMe Critical Warning bitfield (0x04 = reliability degraded).
# TYPE secforge_nvme_critical_warning gauge
# HELP secforge_nvme_percentage_used NVMe Percentage Used (vendor rated-life estimate; >100 = past rated life).
# TYPE secforge_nvme_percentage_used gauge
# HELP secforge_nvme_available_spare NVMe Available Spare percent.
# TYPE secforge_nvme_available_spare gauge
# HELP secforge_nvme_available_spare_threshold NVMe Available Spare Threshold percent.
# TYPE secforge_nvme_available_spare_threshold gauge
# HELP secforge_nvme_media_errors NVMe Media and Data Integrity Errors (monotonic).
# TYPE secforge_nvme_media_errors gauge
# HELP secforge_nvme_temperature_celsius NVMe composite temperature.
# TYPE secforge_nvme_temperature_celsius gauge
# HELP secforge_nvme_data_units_written NVMe Data Units Written (x 512000 bytes, monotonic).
# TYPE secforge_nvme_data_units_written gauge
# HELP secforge_nvme_unsafe_shutdowns NVMe Unsafe Shutdowns (monotonic).
# TYPE secforge_nvme_unsafe_shutdowns gauge
# HELP secforge_nvme_power_on_hours NVMe Power On Hours.
# TYPE secforge_nvme_power_on_hours gauge
# HELP secforge_smart_exporter_last_run_timestamp_seconds Unix time of the last successful exporter run.
# TYPE secforge_smart_exporter_last_run_timestamp_seconds gauge
HDR

  for dev in /dev/nvme[0-9]n1; do
    [[ -e "$dev" ]] || continue
    json=$(smartctl --json -H -A -i "$dev" 2>/dev/null) || true
    if [[ -z "$json" ]] || ! jq -e '.nvme_smart_health_information_log' <<<"$json" >/dev/null 2>&1; then
      logger -t smart-exporter "no valid SMART JSON for $dev"
      continue
    fi
    jq -r --arg dev "$dev" '
      .nvme_smart_health_information_log as $h
      | "device=\"\($dev)\",serial=\"\(.serial_number // "unknown")\",model=\"\(.model_name // "unknown")\"" as $l
      | [
          "secforge_nvme_smart_passed{\($l)} \(if .smart_status.passed then 1 else 0 end)",
          "secforge_nvme_critical_warning{\($l)} \($h.critical_warning // 0)",
          "secforge_nvme_percentage_used{\($l)} \($h.percentage_used // 0)",
          "secforge_nvme_available_spare{\($l)} \($h.available_spare // 0)",
          "secforge_nvme_available_spare_threshold{\($l)} \($h.available_spare_threshold // 0)",
          "secforge_nvme_media_errors{\($l)} \($h.media_errors // 0)",
          "secforge_nvme_temperature_celsius{\($l)} \($h.temperature // 0)",
          "secforge_nvme_data_units_written{\($l)} \($h.data_units_written // 0)",
          "secforge_nvme_unsafe_shutdowns{\($l)} \($h.unsafe_shutdowns // 0)",
          "secforge_nvme_power_on_hours{\($l)} \($h.power_on_hours // 0)"
        ] | .[]' <<<"$json"
  done

  echo "secforge_smart_exporter_last_run_timestamp_seconds $(date +%s)"
} > "$TMPFILE"

chmod 0644 "$TMPFILE"   # world-readable regardless of caller umask (node-exporter runs as nobody)
mv "$TMPFILE" "$OUTFILE"
