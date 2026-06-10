# ADR-0039: Rootless Docker for the self-hosted CI runners

Status: Accepted (rolled out live 2026-06-10)
Date: 2026-06-10
Supersedes: the `usermod -aG docker github-runner` posture in `platform/scripts/github-runners-bootstrap.sh`

## Context

The box runs five self-hosted GitHub Actions runners (one per ecosystem repo:
Security-Forge, ecosystem-control, ecosystem-portal, member-hub, proposal-forge),
all as the single `github-runner` system user. They build container images with
`docker buildx` against a **rootful** Docker daemon, and `github-runner` was a
member of the host `docker` group.

The 2026-06-10 pre-launch pentest demonstrated that this collapses the platform's
entire blast-radius model:

- `docker` group membership is root-equivalent. **Proven PoC:** as `github-runner`,
  `docker run --rm -v /:/host:ro alpine cat /host/etc/rancher/k3s/k3s.yaml` ran with
  container-uid 0 = host root and read the k3s **cluster-admin** kubeconfig.
- That means any code execution in CI — a missing fork-PR guard, a malicious
  `pnpm`/`npm` lifecycle script, a hijacked third-party action, or a poisoned shared
  CI script — escalates to **host root → cluster-admin → every Secret → the image
  signing identity**, bypassing RLS, SpiceDB, NetworkPolicies, and Kyverno (all of
  which live *inside* the cluster, below the CI plane).

A second, more direct path was found at the same time: `/etc/rancher/k3s/k3s.yaml`
had drifted to mode `0644` (world-readable) despite `config.yaml` declaring
`write-kubeconfig-mode: "0600"`, so `github-runner` (and any host user) could read
cluster-admin credentials with a plain `cat`, no Docker required. (Fixed separately —
see Consequences.)

## Decision

**Run the runners' image builds with rootless Docker, and remove `github-runner`
from the `docker` group.**

- Install `docker-ce-rootless-extras` + `uidmap` + `slirp4netns` + `dbus-user-session`.
- `loginctl enable-linger github-runner` and run a per-user `dockerd` as a
  `systemd --user` service for `github-runner` (socket `/run/user/<uid>/docker.sock`).
- Each runner's `.env` sets `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` so jobs
  build against the rootless daemon.
- Remove `github-runner` from the `docker` group; **disable** the rootful
  `docker.service`/`docker.socket` (nothing else uses it — k3s has its own containerd).

Under rootless Docker, container-root maps to `github-runner`'s subuid range
(`165536`), **not** host root. The same `docker run -v /:/host` PoC now sees host
root-owned files as `nobody` and cannot read them — the escalation is closed while
the existing `docker buildx` / `build-push-action` workflows keep working unchanged.

### Alternatives considered

- **`userns-remap` on the rootful daemon** — rejected. A `docker`-group member can
  opt out per-container with `docker run --userns=host`, so it is not a security
  boundary against a hostile CI job.
- **Actions Runner Controller (ephemeral in-cluster runners)** — the correct
  long-term target (ephemeral + no host access), but a large architectural change.
  Rootless Docker is the surgical fix that closes the finding now; ARC remains a
  future option.
- **Keep rootful, add `--ignore-scripts` / fork guards only** — reduces likelihood
  but leaves the root-equivalence intact. Insufficient on its own.

## Consequences

- **Positive:** a compromised CI job is contained to `github-runner`'s unprivileged
  uid + its rootless subuid range. It can no longer reach host root, the k3s
  kubeconfig, or cluster-admin. The "even if an app/CI is compromised, the attacker
  can do nothing" goal now holds at the CI layer too.
- **Build storage** moves from `/var/lib/docker` (rootful) to
  `/opt/github-runner/.local/share/docker` (rootless, overlayfs) on the root volume.
  The old `/var/lib/docker` (~2.7G) is reclaimable.
- **Rootless caveats** validated live before cutover: both a light image with a
  Postgres **service container** + port-mapping (member-hub) and the heavy
  chromium image (proposal-forge) build, push, and cosign-sign successfully rootless.
- **Companion fix (kubeconfig):** `chmod 0600 /etc/rancher/k3s/k3s.yaml` (re-aligns
  the declared `write-kubeconfig-mode`). `ops` keeps plain `kubectl`/`apply-manifest.sh`
  via its own `~/.kube/config` (0600) + `export KUBECONFIG=$HOME/.kube/config` in
  `~/.profile`. Durability: the mode drifted to 0644 once before — verify with
  `platform/scripts/host-config-drift-check.sh` after each reboot.
- **Rollback:** `usermod -aG docker github-runner` + `systemctl enable --now docker`
  + drop the `.env` `DOCKER_HOST` lines → back to rootful. The rootful daemon is
  disabled (not purged), so rollback is one command.

## Live rollout record (2026-06-10)

1. Installed rootless prereqs + stood up rootless dockerd alongside rootful (additive).
2. Proved rootless de-privileges (PoC: rootless `-v /:/host` can't read root files).
3. Fixed the world-readable kubeconfig (0644 → 0600); preserved ops `kubectl`.
4. Canary: member-hub build green on rootless (+ service container).
5. Cut all 5 runners to the rootless socket; **removed `github-runner` from `docker`**
   (verified: rootful socket → `permission denied`); restarted runners.
6. Heavy canary: proposal-forge (chromium) build green on rootless, no docker group.
7. Disabled the rootful `docker.service`/`docker.socket`.
8. Codified in `github-runners-bootstrap.sh` (this ADR) + the teardown script.
