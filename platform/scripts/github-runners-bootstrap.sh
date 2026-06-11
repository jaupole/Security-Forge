#!/usr/bin/env bash
# Bootstrap self-hosted GitHub Actions runners on this box, one per active
# ecosystem repo. Companion to github-runners-teardown.sh — running bootstrap
# then teardown round-trips cleanly with no manual cleanup left over.
#
# What it installs:
#   - Docker CE binaries from the official apt repo (separate from k3s
#     containerd). Builds run ROOTLESS as github-runner — NOT via the rootful
#     daemon and NOT through the docker group — so a compromised CI job cannot
#     `docker run -v /:/host` to host root / cluster-admin. The rootful
#     docker.service is disabled. See ADR-0039 (pentest 2026-06-10).
#   - uidmap + slirp4netns + dbus-user-session + docker-ce-rootless-extras
#     (rootless Docker prerequisites).
#   - pipx + libicu74 (pipx is required for the `Install pinned scanners`
#     step in slow-gate workflows — semgrep/checkov/pip-audit are pipx
#     installs; libicu74 satisfies the runner agent's .NET dep)
#   - github-runner local user with HOME=/opt/github-runner. The /opt path
#     is load-bearing: GHA's job mount namespace bind-mounts /home READ-ONLY,
#     which breaks any runner whose work dir lives under /home. Do NOT
#     "fix" this back to /home/github-runner.
#   - One actions-runner install per repo under /opt/github-runner/runners/<slug>,
#     each with DOCKER_HOST in its .env pointed at the rootless dockerd.
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
  [proposal-forge]=proposal-forge
  [business-manager]=business-manager
)

# Pinned runner version. Bump deliberately — GitHub auto-updates runners
# at job start anyway, but pinning gives a known-good starting tarball.
RUNNER_VERSION="2.321.0"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"

echo ">>> installing Docker CE binaries from the official apt repo"
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
  # docker-ce-rootless-extras provides dockerd-rootless-setuptool.sh + rootlesskit.
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    docker-ce-rootless-extras 2>&1 | tail -3
else
  echo "  docker already installed, skipping"
fi

# SECURITY (pentest 2026-06-10 / ADR-0039): the rootful system daemon is NOT
# used — builds run rootless (set up below). Disable it so that a docker-group
# member could never `docker run -v /:/host` to host root + cluster-admin.
sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true

echo ">>> installing pipx + libicu74 + rootless-docker prerequisites"
# uidmap (newuidmap/newgidmap), slirp4netns, dbus-user-session are required by
# rootless Docker. Run unconditionally (the docker block above is guarded).
sudo apt-get install -y -qq pipx libicu74 uidmap slirp4netns dbus-user-session 2>&1 | tail -3

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

# SECURITY (pentest 2026-06-10 / ADR-0039): github-runner is deliberately NOT
# in the docker group. Builds use a rootless per-user dockerd — container-root
# maps to subuid 165536, never host root, so `docker run -v /:/host` cannot
# read the k3s admin kubeconfig or otherwise reach cluster-admin.
echo ">>> setting up rootless Docker for github-runner (no docker group)"
sudo loginctl enable-linger github-runner
grep -q '^github-runner:' /etc/subuid || echo 'github-runner:165536:65536' | sudo tee -a /etc/subuid >/dev/null
grep -q '^github-runner:' /etc/subgid || echo 'github-runner:165536:65536' | sudo tee -a /etc/subgid >/dev/null
GR_UID=$(id -u github-runner)
sudo -u github-runner env \
  XDG_RUNTIME_DIR="/run/user/${GR_UID}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${GR_UID}/bus" \
  PATH=/usr/bin:/usr/sbin:/bin:/usr/local/bin \
  dockerd-rootless-setuptool.sh install --force 2>&1 | tail -5 || true
sudo -u github-runner env XDG_RUNTIME_DIR="/run/user/${GR_UID}" \
  systemctl --user enable --now docker.service 2>&1 | tail -2 || true

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

  # An interrupted config.sh leaves .credentials WITHOUT .runner — config.sh
  # then refuses ("already configured") even though the runner never came
  # online. The `! -f .runner` check below would re-enter config.sh and abort.
  # Treat that as partial state and reset the local config so we register clean
  # (the GitHub-side runner, if any, is replaced by --replace below).
  if [ -f "${RUNNER_DIR}/.credentials" ] && [ ! -f "${RUNNER_DIR}/.runner" ]; then
    echo "    ${REPO}: clearing partial runner config (.credentials without .runner)"
    sudo -u github-runner bash -c "cd '${RUNNER_DIR}' && rm -f .credentials .credentials_rsaparams .runner .service"
  fi

  # Skip registration if .runner exists — runner already configured + online.
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
    # One repo's config failure must NOT abort the whole loop (set -e + the
    # tail pipeline would otherwise kill every later repo). Warn and continue.
    if ! sudo -u github-runner bash -c "cd '${RUNNER_DIR}' && ./config.sh \
      --unattended \
      --url https://github.com/${OWNER}/${REPO} \
      --token ${REG_TOKEN} \
      --name secforge-${slug} \
      --labels self-hosted,secforge,linux,x64 \
      --work _work \
      --replace" 2>&1 | tail -5; then
      echo "    WARN: ${REPO} runner config failed — skipping (re-run to retry)"
      continue
    fi
  else
    echo "    runner already registered, skipping config.sh"
  fi

  # Point this runner's jobs at the rootless dockerd (ADR-0039). The runner
  # exports vars from <RUNNER_DIR>/.env into every job's environment.
  RUN_ENV="${RUNNER_DIR}/.env"
  sudo -u github-runner bash -c "touch '${RUN_ENV}'; grep -q DOCKER_HOST '${RUN_ENV}' || printf 'DOCKER_HOST=unix:///run/user/${GR_UID}/docker.sock\nXDG_RUNTIME_DIR=/run/user/${GR_UID}\n' >> '${RUN_ENV}'"

  echo "  writing systemd unit actions.runner.${slug}.service"
  # Sandboxing is intentionally OFF here:
  #   - ProtectHome=no — re-imposes RO /home which is what the /opt move
  #     avoids, but also blocks runners from touching their own work tree
  #     under /opt if a future systemd hardens the default.
  #   - ProtectSystem=no — rootless `docker build` writes its layer cache under
  #     the runner's HOME (/opt/github-runner/.local/share/docker).
  # Run.sh is single-shot per job dispatch; systemd respawns it via
  # Restart=always between jobs. The rootless dockerd is a github-runner
  # systemd --user service kept alive by enable-linger (started at boot), so
  # the runner no longer depends on the (disabled) rootful docker.service.
  sudo tee "/etc/systemd/system/actions.runner.${slug}.service" > /dev/null <<EOF
[Unit]
Description=GitHub Actions self-hosted runner for ${OWNER}/${REPO}
After=network-online.target
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
echo "Runners are registered and live (ROOTLESS Docker, no docker group). Verify:"
echo "  systemctl --no-pager status 'actions.runner.*.service'"
echo "  sudo -u github-runner XDG_RUNTIME_DIR=/run/user/\$(id -u github-runner) systemctl --user status docker"
echo "  https://github.com/${OWNER}/<repo>/settings/actions/runners"
echo
echo "Workflows must target the secforge label, e.g.:"
echo "  runs-on: [self-hosted, secforge]"
echo "ubuntu-latest jobs will queue forever — GHA-hosted spending is \$0."
echo
echo "Remember to revoke the PAT at https://github.com/settings/tokens"
