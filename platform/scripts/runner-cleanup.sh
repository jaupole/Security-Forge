#!/usr/bin/env bash
# runner-cleanup.sh — reclaim disk consumed by self-hosted GitHub Actions
# runners on the secforge-prod host.
#
# Run as root (or github-runner user with sudo docker).
# Intended to be scheduled via cron — see platform/host/runner-cleanup.cron.
#
# What it does:
#   1. Deletes runner _work job directories older than WORK_MAX_AGE_DAYS days.
#      _work holds checkout + build output per-run.
#   2. Prunes per-runner cache dirs (.cache, .npm, .local) older than
#      CACHE_MAX_AGE_DAYS days. These grow without bound across runs and are
#      the largest root-partition consumer after _work.
#   3. Prunes dangling Docker volumes (CI build steps that use docker leave
#      anonymous volumes behind; 149 volumes / 7.7 GB were found on 2026-06-09
#      after ~32 days without pruning).
#   4. Prunes the Docker build cache (docker builder prune --keep-storage).
#      BuildKit layer cache accumulates across image builds; safe to prune as
#      layers are re-fetchable from GHCR on next build.
#
# NOT done here:
#   - containerd image GC: handled by k3s kubelet image-gc-high-threshold=70
#     (set in /etc/rancher/k3s/config.yaml 2026-06-07). crictl rmi --prune
#     can be added below if GC proves too slow.
#
# Usage: sudo bash platform/scripts/runner-cleanup.sh
#
# Scheduled: /etc/cron.d/github-runner-cleanup (Mon/Wed/Fri 04:00, as root).

set -euo pipefail

RUNNER_BASE="${RUNNER_BASE:-/opt/github-runner/runners}"
WORK_MAX_AGE_DAYS="${WORK_MAX_AGE_DAYS:-1}"
CACHE_MAX_AGE_DAYS="${CACHE_MAX_AGE_DAYS:-7}"
# Keep 500 MB of BuildKit layer cache; layers re-pull from GHCR on next build.
BUILDER_KEEP_STORAGE="${BUILDER_KEEP_STORAGE:-500mb}"

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

# ── 2. Runner cache directories ───────────────────────────────────────────────
log "Pruning per-runner cache dirs older than ${CACHE_MAX_AGE_DAYS}d (.cache, .npm, .local)..."

before_cache=$(df --output=avail / | tail -1)

# Each runner home dir is /opt/github-runner/runners/<name>. The per-runner
# user home at /home/github-runner* may also hold caches; this covers both.
for cache_parent in "${RUNNER_BASE}"/*  /home/github-runner*; do
  [[ -d "${cache_parent}" ]] || continue
  for cache_dir in "${cache_parent}/.cache" "${cache_parent}/.npm" "${cache_parent}/.local"; do
    [[ -d "${cache_dir}" ]] || continue
    find "${cache_dir}" -maxdepth 1 -mindepth 1 \
      -mtime "+${CACHE_MAX_AGE_DAYS}" \
      -print0 \
    | xargs -0 --no-run-if-empty rm -rf
  done
done

after_cache=$(df --output=avail / | tail -1)
reclaimed_cache=$(( (after_cache - before_cache) / 1024 ))
log "Cache cleanup done — approx ${reclaimed_cache} MiB reclaimed from /"

# ── 3. Docker dangling volumes ────────────────────────────────────────────────
if id github-runner &>/dev/null; then
  ruid="$(id -u github-runner)"
  rootless_docker() {
    sudo -u github-runner env XDG_RUNTIME_DIR="/run/user/${ruid}" DOCKER_HOST="unix:///run/user/${ruid}/docker.sock" docker "$@"
  }
  # CI uses the ROOTLESS docker daemon (github-runner, uid 1001); the rootful
  # docker.service is disabled (ADR-0039). Prune the rootless socket as that
  # user - NOT plain 'docker' as root, which reaches the empty/disabled root
  # daemon and silently skips everything (the bug that let the store hit 13G).
  if rootless_docker info &>/dev/null; then
    log "Pruning dangling Docker volumes (rootless)..."
    rootless_docker volume prune -f
    log "Pruning dangling Docker images (rootless)..."
    rootless_docker image prune -f
    log "Pruning Docker build cache (rootless, keeping ${BUILDER_KEEP_STORAGE})..."
    rootless_docker builder prune -f --keep-storage "${BUILDER_KEEP_STORAGE}"
  else
    log "Rootless Docker (github-runner) not reachable - skipping volume + builder prune"
  fi
else
  log "github-runner user not present - skipping Docker prune"
fi

log "Done."
