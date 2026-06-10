#!/usr/bin/env bash
# Tear down the self-hosted GitHub Actions runners installed on this
# box. Run this when major development winds down to stop the four
# `actions.runner.*.service` units, deregister the runners from each
# repo (so the GitHub UI doesn't show stale "Offline" runners
# forever), uninstall Docker, and remove the github-runner user +
# workspace.
#
# Requires:
#   - sudo (passwordless or interactive)
#   - A short-lived GitHub PAT with `repo` scope for deregistration
#     calls (same scope as bootstrap). Set: GITHUB_PAT=ghp_...
#
# Usage:
#   GITHUB_PAT=ghp_... bash github-runners-teardown.sh
#
# Idempotent — re-running after partial teardown finishes cleanly.

set -euo pipefail
IFS=$'\n\t'

if [ -z "${GITHUB_PAT:-}" ]; then
  echo "GITHUB_PAT env var is required (PAT with `repo` scope)."
  echo "Generate one at https://github.com/settings/tokens/new"
  echo "Revoke it immediately after this script finishes."
  exit 1
fi

OWNER=jaupole
declare -A REPOS=(
  [security-forge]=Security-Forge
  [ecosystem-control]=ecosystem-control
  [ecosystem-portal]=ecosystem-portal
  [member-hub]=member-hub
  [proposal-forge]=proposal-forge
)

echo ">>> stopping + disabling systemd services"
for slug in "${!REPOS[@]}"; do
  sudo systemctl disable --now "actions.runner.${slug}.service" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/actions.runner.${slug}.service"
done
sudo systemctl daemon-reload

echo ">>> deregistering each runner from GitHub"
for slug in "${!REPOS[@]}"; do
  REPO="${REPOS[$slug]}"
  RUNNER_DIR="/opt/github-runner/runners/${slug}"
  if [ ! -d "$RUNNER_DIR" ]; then
    echo "  ${REPO}: no runner dir, skipping"
    continue
  fi
  # Fetch a fresh REMOVAL token (different endpoint than registration)
  REMOVE_TOKEN=$(curl -sS -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/remove-token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [ -z "$REMOVE_TOKEN" ]; then
    echo "  ${REPO}: failed to fetch removal token (continuing)"
    continue
  fi
  sudo -u github-runner bash -c "cd ${RUNNER_DIR} && ./config.sh remove --token ${REMOVE_TOKEN}" 2>&1 | tail -3 || true
done

echo ">>> tearing down rootless Docker for github-runner (ADR-0039)"
GR_UID=$(id -u github-runner 2>/dev/null || true)
if [ -n "${GR_UID}" ]; then
  sudo -u github-runner env XDG_RUNTIME_DIR="/run/user/${GR_UID}" \
    dockerd-rootless-setuptool.sh uninstall 2>&1 | tail -3 || true
  sudo loginctl disable-linger github-runner 2>/dev/null || true
fi

echo ">>> removing github-runner user + workspace"
sudo userdel -r github-runner 2>/dev/null || true
sudo rm -rf /opt/github-runner
# clean up the subordinate id ranges added for rootless Docker
sudo sed -i '/^github-runner:/d' /etc/subuid /etc/subgid 2>/dev/null || true

echo ">>> uninstalling Docker"
sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true
sudo apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras 2>&1 | tail -3
sudo apt-get autoremove -y -qq 2>&1 | tail -3
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc

echo ">>> done"
echo "Remember to revoke the PAT at https://github.com/settings/tokens"
echo "Workflows still reference 'self-hosted, secforge' — switch them"
echo "back to 'ubuntu-latest' BEFORE the next push or queued jobs will"
echo "hang forever waiting for a runner."
