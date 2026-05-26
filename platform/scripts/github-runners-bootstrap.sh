#!/usr/bin/env bash
# Bootstrap four self-hosted GitHub Actions runners on this box, one per
# active ecosystem repo. Companion to github-runners-teardown.sh — running
# bootstrap then teardown round-trips cleanly with no manual cleanup left
# over.
#
# What it installs:
#   - Docker CE from the official apt repo (separate from k3s containerd,
#     needed for `docker build/push/login` in workflows)
#   - pipx + libicu74 (pipx is required for the `Install pinned scanners`
#     step in slow-gate workflows — semgrep/checkov/pip-audit are pipx
#     installs; libicu74 satisfies the runner agent's .NET dep)
#   - github-runner local user with HOME=/opt/github-runner. The /opt path
#     is load-bearing: GHA's job mount namespace bind-mounts /home READ-ONLY,
#     which breaks any runner whose work dir lives under /home. Do NOT
#     "fix" this back to /home/github-runner.
#   - One actions-runner install per repo under /opt/github-runner/runners/<slug>
#   - One systemd unit per runner with sandboxing DISABLED. Stock
#     systemd-hardened defaults (ProtectHome/ProtectSystem) re-impose the
#     read-only /home that the /opt move exists to avoid, so they are
#     explicitly disabled below.
#
# Requires:
#   - sudo (passwordless or interactive)
#   - A short-lived GitHub PAT with `repo` scope for registration calls.
#     Generate at https://github.com/settings/tokens/new, set:
#       GITHUB_PAT=ghp_...
#     Revoke it immediately after this script finishes.
#
# Usage:
#   GITHUB_PAT=ghp_... bash github-runners-bootstrap.sh
#
# Idempotent — re-running over a partial install finishes cleanly.

set -euo pipefail
IFS=$'\n\t'

if [ -z "${GITHUB_PAT:-}" ]; then
  echo "GITHUB_PAT env var is required (PAT with \`repo\` scope)."
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
)

# Pinned runner version. Bump deliberately — GitHub auto-updates runners
# at job start anyway, but pinning gives a known-good starting tarball.
RUNNER_VERSION="2.321.0"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"

echo ">>> installing Docker CE from the official apt repo"
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin 2>&1 | tail -3
  sudo systemctl enable --now docker.service
else
  echo "  docker already installed, skipping"
fi

echo ">>> installing pipx + libicu74 (runner deps + scanner deps)"
sudo apt-get install -y -qq pipx libicu74 2>&1 | tail -3

echo ">>> creating github-runner user with HOME=/opt/github-runner"
if ! id github-runner >/dev/null 2>&1; then
  # --home /opt/... is mandatory; GHA bind-mounts /home READ-ONLY inside
  # the job mount namespace, breaking any runner whose work tree lives
  # there. /opt is left writable.
  sudo useradd --system --create-home --home-dir /opt/github-runner \
    --shell /bin/bash github-runner
else
  echo "  github-runner user already exists, skipping"
fi
sudo usermod -aG docker github-runner

echo ">>> ensuring pipx is on github-runner's PATH"
sudo -u github-runner bash -lc 'pipx ensurepath' 2>&1 | tail -3 || true

echo ">>> downloading the actions-runner tarball (v${RUNNER_VERSION})"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "${WORK}/${RUNNER_TARBALL}" "${RUNNER_URL}"

echo ">>> installing one runner per repo"
for slug in "${!REPOS[@]}"; do
  REPO="${REPOS[$slug]}"
  RUNNER_DIR="/opt/github-runner/runners/${slug}"
  echo "  ${REPO} -> ${RUNNER_DIR}"

  sudo -u github-runner mkdir -p "${RUNNER_DIR}"
  if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
    sudo tar -xzf "${WORK}/${RUNNER_TARBALL}" -C "${RUNNER_DIR}"
    sudo chown -R github-runner:github-runner "${RUNNER_DIR}"
    # bin/ and externals/ unpack as version-suffixed dirs in newer tarballs;
    # installdependencies.sh + run.sh expect the symlink shape. tar already
    # restores it from the archive on a clean extract — only fix it up if
    # the symlinks are broken (re-extract over an existing dir).
    for link in bin externals; do
      if [ -L "${RUNNER_DIR}/${link}" ] && [ ! -e "${RUNNER_DIR}/${link}" ]; then
        TARGET=$(readlink "${RUNNER_DIR}/${link}")
        if [ ! -d "${RUNNER_DIR}/${TARGET}" ]; then
          # symlink points at a versioned dir that doesn't exist — recreate
          REAL=$(ls -d "${RUNNER_DIR}/${link}".* 2>/dev/null | head -1 || true)
          if [ -n "$REAL" ]; then
            sudo -u github-runner ln -sfn "$(basename "$REAL")" \
              "${RUNNER_DIR}/${link}"
          fi
        fi
      fi
    done
    sudo "${RUNNER_DIR}/bin/installdependencies.sh" 2>&1 | tail -3
  else
    echo "    runner already extracted, skipping unpack"
  fi

  # Skip registration if .runner exists — runner already configured.
  if [ ! -f "${RUNNER_DIR}/.runner" ]; then
    REG_TOKEN=$(curl -sS -X POST \
      -H "Authorization: token ${GITHUB_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/registration-token" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
    if [ -z "$REG_TOKEN" ]; then
      echo "    ${REPO}: failed to fetch registration token, skipping"
      continue
    fi
    sudo -u github-runner bash -c "cd ${RUNNER_DIR} && ./config.sh \
      --unattended \
      --url https://github.com/${OWNER}/${REPO} \
      --token ${REG_TOKEN} \
      --name secforge-${slug} \
      --labels self-hosted,secforge,linux,x64 \
      --work _work \
      --replace" 2>&1 | tail -5
  else
    echo "    runner already registered, skipping config.sh"
  fi

  echo "  writing systemd unit actions.runner.${slug}.service"
  # Sandboxing is intentionally OFF here:
  #   - ProtectHome=no — re-imposes RO /home which is what the /opt move
  #     avoids, but also blocks runners from touching their own work tree
  #     under /opt if a future systemd hardens the default.
  #   - ProtectSystem=no — `docker build` writes layer cache outside /opt.
  # Run.sh is single-shot per job dispatch; systemd respawns it via
  # Restart=always between jobs.
  sudo tee "/etc/systemd/system/actions.runner.${slug}.service" > /dev/null <<EOF
[Unit]
Description=GitHub Actions self-hosted runner for ${OWNER}/${REPO}
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=github-runner
Group=github-runner
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=always
RestartSec=15s
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min
ProtectHome=no
ProtectSystem=no

[Install]
WantedBy=multi-user.target
EOF
done

echo ">>> reloading systemd + starting all runner services"
sudo systemctl daemon-reload
for slug in "${!REPOS[@]}"; do
  sudo systemctl enable --now "actions.runner.${slug}.service"
done

echo ">>> done"
echo "Runners are registered and live. Verify with:"
echo "  systemctl --no-pager status 'actions.runner.*.service'"
echo "  https://github.com/${OWNER}/<repo>/settings/actions/runners"
echo
echo "Workflows must target the secforge label, e.g.:"
echo "  runs-on: [self-hosted, secforge]"
echo "ubuntu-latest jobs will queue forever — GHA-hosted spending is \$0."
echo
echo "Remember to revoke the PAT at https://github.com/settings/tokens"
