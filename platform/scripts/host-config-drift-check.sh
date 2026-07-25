#!/usr/bin/env bash
# host-config-drift-check.sh — detect drift between the codified host files
# (platform/host/**) and what is actually installed on this host.
#
# WHY: the host-level files below are codified in the repo and installed by
# platform/components/00-host-bootstrap.sh, which treats the repo as
# source-of-truth — it `cmp`s repo→host and OVERWRITES the host copy (and
# restarts k3s) on its next run. If anyone hand-edits a host file without
# mirroring the change back into the repo, the next bootstrap run silently
# reverts it. This script surfaces that divergence before it bites.
#
# Origin: 2026-06-07 — write-kubeconfig-mode="0600" and a secrets-encryption
# note had drifted onto the host but never into platform/host/k3s/config.yaml;
# a bootstrap re-run would have reverted the kubeconfig hardening to 0644.
#
# Usage:  sudo platform/scripts/host-config-drift-check.sh
# Exit:   0 = all in sync   |   1 = drift found (prints unified diffs)
#
# This is the mapping from 00-host-bootstrap.sh's `install` calls. When that
# script gains/loses a codified host file, update the PAIRS list here too.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
HOST="$PLATFORM_DIR/host"

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: run as root — several host files (e.g. k3s/config.yaml) are 0600 root." >&2
  echo "       sudo $0" >&2
  exit 2
fi

# repo-relative path (under platform/host/) : installed host path
PAIRS=(
  "k3s/config.yaml:/etc/rancher/k3s/config.yaml"
  "k3s/audit-policy.yaml:/etc/rancher/k3s/audit-policy.yaml"
  "sysctl/99-secforge-hardening.conf:/etc/sysctl.d/99-secforge-hardening.conf"
  "sysctl/91-k3s-kubelet.conf:/etc/sysctl.d/91-k3s-kubelet.conf"
  "modprobe.d/secforge-blacklist.conf:/etc/modprobe.d/secforge-blacklist.conf"
  "node-exporter/mount-count-exporter.sh:/usr/local/sbin/mount-count-exporter.sh"
  "node-exporter/mount-count-exporter.service:/etc/systemd/system/mount-count-exporter.service"
  "node-exporter/mount-count-exporter.timer:/etc/systemd/system/mount-count-exporter.timer"
  "node-exporter/gha-runner-exporter.sh:/usr/local/sbin/gha-runner-exporter.sh"
  "node-exporter/gha-runner-exporter.service:/etc/systemd/system/gha-runner-exporter.service"
  "node-exporter/gha-runner-exporter.timer:/etc/systemd/system/gha-runner-exporter.timer"
)

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

drift=0
for pair in "${PAIRS[@]}"; do
  rel="${pair%%:*}"; dst="${pair#*:}"
  src="$HOST/$rel"
  if [ ! -e "$src" ]; then yellow "SKIP   repo file absent: platform/host/$rel"; continue; fi
  if [ ! -e "$dst" ]; then red "MISSING on host: $dst   (repo has platform/host/$rel)"; drift=1; continue; fi
  if cmp -s "$src" "$dst"; then
    green "OK     $dst"
  else
    red   "DRIFT  $dst  ≠  platform/host/$rel"
    diff -u "$src" "$dst" | sed 's/^/         /' || true
    drift=1
  fi
done

echo
if [ "$drift" -ne 0 ]; then
  red "✗ Host config drift detected."
  red "  Reconcile, do NOT leave divergent:"
  red "   • host change is intended  → update platform/host/<rel> to match + commit"
  red "   • repo is correct          → sudo platform/components/00-host-bootstrap.sh (re-installs + restarts k3s on diff)"
  exit 1
fi
green "✓ All codified host files match what is installed on the host."
