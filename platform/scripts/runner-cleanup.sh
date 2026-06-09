#!/usr/bin/env bash
# runner-cleanup.sh — reclaim disk consumed by self-hosted GitHub Actions
# runners on the secforge-prod host.
#
# Run as root (or github-runner user with sudo docker).
# Intended to be scheduled via cron — see platform/host/runner-cleanup.cron.
#
# What it does:
#   1. Deletes runner _work job directories older than WORK_MAX_AGE_DAYS days.
#      _work holds checkout + build output; caches (.cache, .npm, setup-pnpm)
#      are intentionally left intact to keep builds fast.
#   2. Prunes dangling Docker volumes (CI build steps that use docker leave
#      anonymous volumes behind; 149 volumes / 7.7 GB were found on 2026-06-09
#      after ~32 days without pruning).
#
# NOT done here:
#   - containerd image GC: handled by k3s kubelet image-gc-high-threshold=70
#     (set in /etc/rancher/k3s/config.yaml 2026-06-07). crictl rmi --prune
#     can be added below if GC proves too slow.
#
# Usage: sudo bash platform/scripts/runner-cleanup.sh

set -euo pipefail

RUNNER_BASE="${RUNNER_BASE:-/opt/github-runner/runners}"
WORK_MAX_AGE_DAYS="${WORK_MAX_AGE_DAYS:-1}"

log() { printf '[runner-cleanup] %s\n' "$*"; }

# ── 1. Runner _work directories ──────────────────────────────────────────────
log "Scanning ${RUNNER_BASE}/*/_work for dirs older than ${WORK_MAX_AGE_DAYS}d..."

before_root=$(df --output=avail / | tail -1)

# Find subdirectories inside each _work (one dir per workflow run) that are
# older than WORK_MAX_AGE_DAYS. Don't delete _work itself — the runner creates
# it on first use and expects it to exist.
find "$RUNNER_BASE" -mindepth 3 -maxdepth 3 \
  -path "*/_work/*" -type d \
  -mtime "+${WORK_MAX_AGE_DAYS}" \
  -print0 \
| xargs -0 --no-run-if-empty rm -rf

after_root=$(df --output=avail / | tail -1)
reclaimed=$(( (after_root - before_root) / 1024 ))
log "_work cleanup done — approx ${reclaimed} MiB reclaimed from /"

# ── 2. Docker dangling volumes ────────────────────────────────────────────────
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  log "Pruning dangling Docker volumes..."
  docker volume prune -f
else
  log "Docker not available or not running — skipping volume prune"
fi

log "Done."
