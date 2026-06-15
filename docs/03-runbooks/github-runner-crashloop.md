# GitHub Actions runner crash-loop / SessionConflict

Self-hosted CI runners live on the secforge host at `/opt/github-runner/runners/<app>/`,
one systemd unit `actions.runner.<app>.service` each, all run as user `github-runner`.

## Symptom
- A repo's CI jobs sit **Queued / "Waiting for a runner"** and never start, or a runner
  flaps online/offline under GitHub -> Settings -> Actions -> Runners.
- `systemctl status actions.runner.<app>.service` shows **active (running)** but with a
  high `NRestarts`, and the journal repeats:
  ```
  run.sh[...]: A session for this runner already exists.
  run.sh[...]: Stop retry on SessionConflictException after retried for 240 seconds.
  systemd[1]: actions.runner.<app>.service: Scheduled restart job, restart counter is at N.
  systemd[1]: Found left-over process <pid> (Runner.Listener) in control group while starting unit. Ignoring.
  ```

### Why it is silent by default
The runner exits **status 0** on a session conflict (`Result=success`), so the unit never
enters systemd `failed` state; the ~4 min/cycle cadence never trips `StartLimitBurst`
(5-in-10s). Nothing keyed on "failed" units fires, and GitHub emails on *failed* workflows,
not *queued* ones. The Wazuh rules below were added to break that silence.

## Root cause
The unit has `KillMode=process` (upstream default; protects an in-flight job from a
`systemctl stop`). On restart systemd kills only the `run.sh` MainPID and **leaves the old
`Runner.Listener` alive in the cgroup**. That orphan keeps holding the GitHub runner
session, so every freshly-started listener fails to acquire it (`SessionConflictException`)
and `Restart=always` respawns it - forever.

## Self-heal (in place since 2026-06-15)
Each unit has an `ExecStartPre` that sweeps a leftover listener before (re)start:
```
ExecStartPre=-/usr/bin/pkill -9 -u github-runner -f <RUNNER_DIR>/bin/Runner.Listener
```
- Leading `-` ignores `pkill` exit 1 (no match = the healthy case).
- Scoped to `Runner.Listener` so an in-flight `Runner.Worker` job is never touched.
- Live via drop-in `/etc/systemd/system/actions.runner.<app>.service.d/10-clear-orphan-listener.conf`;
  codified in the unit heredoc of `platform/scripts/github-runners-bootstrap.sh` so a fresh
  bootstrap inherits it.

## Manual fix (belt-and-suspenders)
```bash
s=ecosystem-control   # the affected runner
sudo systemctl stop "actions.runner.$s.service"
sudo pkill -9 -u github-runner -f "/opt/github-runner/runners/$s/"   # sweep orphans
sudo systemctl reset-failed "actions.runner.$s.service"
sudo systemctl start "actions.runner.$s.service"
# verify exactly ONE listener + NRestarts frozen:
ps -eo cmd | grep "[R]unner.Listener run" | sed -E 's#.*/runners/([^/]+)/.*#\1#' | sort | uniq -c
systemctl show -p NRestarts "actions.runner.$s.service"
```
Do **not** change `KillMode` - it is what lets a `systemctl stop` avoid killing a running job.

## Alerting (Wazuh)
`platform/manifests/wazuh/local-rules/github-runner.xml`, applied by
`platform/components/07q-wazuh-github-runner-rules.sh`:

| Rule | Level | Fires on |
|------|-------|----------|
| 100210 | 3 | runner unit auto-restarted by systemd (`if_sid 40700` + unit name + "Scheduled restart job") |
| 100211 | 3 | "A session for this runner already exists" |
| 100212 | 12 | **escalation**: 3+ of the above (`if_matched_group github_runner_event`) in 15 min -> `system_admin_attention` -> Maintenance Required dashboard |

Re-apply after editing the XML:
```bash
sudo bash ~/secforge/platform/components/07q-wazuh-github-runner-rules.sh
```
Test without a real loop:
```bash
printf 'Jun 15 00:00:00 host run.sh[1]: A session for this runner already exists.\n' \
 | sudo k3s kubectl exec -i -n wazuh wazuh-manager-0 -c wazuh-manager -- /var/ossec/bin/wazuh-logtest
```
Wazuh-rule gotchas learned here: this build rejects `<pcre2>`; OS_Regex `.+` is not PCRE (AND
two contiguous substrings via `<match>`+`<regex>` instead); a rule matching a **decoded**
systemd line needs `<if_sid>40700</if_sid>` (a top-level `<match>` only fires on undecoded
logs); rule IDs 100200-100203 belong to `trivy_rules.xml` - check the live pod's
`/var/ossec/etc/rules/*.xml`, not just the repo.

## Disk hygiene (`runner-cleanup.sh`)
`platform/scripts/runner-cleanup.sh` (cron `platform/host/runner-cleanup.cron` ->
`/etc/cron.d/runner-cleanup`, Mon/Wed/Fri 04:00 Europe/Berlin, as root) deletes `_work` >1d +
per-runner caches >7d and prunes the **rootless** docker (volumes + dangling images + build
cache, keeping tagged images as warm cache). Run on demand: `sudo bash ~/secforge/platform/scripts/runner-cleanup.sh`.

Two bugs fixed 2026-06-15 that had stopped it ever running on this host:
1. it called plain `docker` as root, but root `docker.service` is disabled (ADR-0039,
   rootless-only) -> `docker info` failed -> it silently skipped all docker pruning. It now
   drops to `github-runner` against `unix:///run/user/<uid>/docker.sock`.
2. the cron hardcoded `/root/secforge` (nonexistent; the clone is `/home/ops/secforge`) ->
   it errored `No such file or directory` every day.

## Backup / DR coverage for this surface
- **Host config** (systemd `ExecStartPre`, `/etc/cron.d/runner-cleanup`, `runner-cleanup.sh`)
  is NOT in Velero (host filesystem). Recover from git: re-run `github-runners-bootstrap.sh`
  (units carry the self-heal) and `cp platform/host/runner-cleanup.cron /etc/cron.d/`.
- **Wazuh rules** live on the manager PV (captured by Velero file-level backup) and are also
  re-derivable from git via `07q`.
- Nothing on this surface depends on the k3s datastore.

## Related
- ADR-0039 rootless docker for CI runners (`docs/02-decisions/0039-rootless-docker-for-ci-runners.md`)
- Fleet CI (`docs/02-decisions/0040-fleet-ci-reusable-build-and-sudoers-gated-deploy.md`)
- Commits `7e0b69c` (self-heal + Wazuh alert), `6448042` (cleanup rootless fix), `e92e154` (cron path/schedule).
