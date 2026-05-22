# Component 11 — Wazuh host agent (native install)

## What this is

Native `wazuh-agent` installed on the bare-metal host as a `systemd` service, configured to give Wazuh full visibility into the host (FIM, syscollector, rootcheck, SCA, host log streams, auditd events, fail2ban events) — the things the in-cluster `wazuh-agent` DaemonSet (component `07b-wazuh-agent.sh`) cannot see because of pod-namespace isolation.

## What it replaces

`platform/components/07b-wazuh-agent.sh` deploys a hardened DaemonSet that monitors the host via `hostPath` mounts (`/host/etc`, `/host/usr/bin`, etc.). That pattern works for File Integrity Monitoring on the mounted paths and for tailing pod logs, but several Wazuh modules hardcode literal paths — `syscollector` reads `/var/lib/dpkg/status`, `rootcheck` scans literal `/`, SCA policies run shell against the container, `auditd` integration expects `/var/log/audit/`. None of these honour the `/host/*` indirection.

Component 11 sidesteps the problem by running the agent natively on the host. Once 10 is verified to be reporting, **delete `07b-wazuh-agent.sh` from `platform/components/` and the `wazuh-agent` namespace from the cluster** — both become dead code. The teardown of the in-cluster artifacts is automated at the end of `11-wazuh-host-agent.sh` (gated on the native agent reporting `Active`).

## Sub-components and execution order

| Script | What it does |
|---|---|
| `11-wazuh-host-agent.sh` | Adds Wazuh apt repo, installs `wazuh-agent` (version pinned), renders `ossec.conf` from the template here, registers with the in-cluster manager, starts the systemd unit, deletes the old DaemonSet once the native agent is reporting. |
| `11a-auditd.sh` | Installs `auditd` + `audispd-plugins`, drops the curated ruleset (`secforge.audit.rules`), restarts `auditd`. The agent's `<localfile>` for `/var/log/audit/audit.log` (already in the rendered `ossec.conf`) starts producing audit events on the next read cycle. |
| `11b-fail2ban.sh` | Installs `fail2ban`, drops the `fail2ban/secforge.local` sshd jail config, restarts. The agent's `<localfile>` for `/var/log/fail2ban.log` (already in the rendered `ossec.conf`) feeds Wazuh both failed-attempt and ban events. |

`install-all.sh` runs them in the alphanumeric order above. Each is idempotent.

## What the rendered `ossec.conf` covers

- **Manager connection:** `wazuh-manager-agents.wazuh.svc.cluster.local:1514` (reachable from the host via k3s service IP routing — single-node cluster, the host *is* a node, kube-proxy handles it).
- **FIM:** realtime watch on `/etc`, scheduled scans on `/usr/bin`, `/usr/sbin`, `/boot`, `/root`. Includes the `<ignore>` list for known-noisy paths (`/etc/mtab`, `/etc/random-seed`, etc.).
- **Syscollector (full):** hardware, os, network interfaces, network protocols, packages, processes, ports — all enabled. Works because the agent runs in the host's namespaces.
- **Rootcheck:** full default profile (signature-based plus heuristic checks for hidden files/processes).
- **SCA:** CIS Ubuntu policy enabled, 12-hour scan interval. First scan runs at agent start (`scan_on_start: yes`).
- **Logcollector — host streams:** `/var/log/auth.log`, `/var/log/syslog`, `/var/log/dpkg.log`, `/var/log/apt/history.log`, `journald` (native), `/var/log/audit/audit.log`, `/var/log/fail2ban.log`.
- **Logcollector — pod streams:** `/var/log/pods/openbao_*/openbao/*.log`, `/var/log/pods/keycloak_*/keycloak/*.log` (kubelet writes container logs here on every node — no DaemonSet needed to reach them).

## What this phase does NOT add (deliberate scope)

These are real detection capabilities. Each is its own follow-on component when (or if) appetite exists:

- **Wazuh active response** to events that originate inside the cluster (Keycloak login burst → Hetzner Cloud Firewall API ban). Requires OpenBao secret + VSO binding for the Hetzner API token. Tracked as future component `11c-wazuh-active-response.sh`.
- **NIDS layer (Suricata + ET Open)** feeding Wazuh. Catches known C2 / exploit payload / exfil patterns that nothing else sees. 1-2 days install + tuning. Future component `11d-suricata.sh`.
- **Wazuh Vulnerability Detection module** (CVE feed against installed packages). Trivial to enable but produces a steady stream of "Ubuntu hasn't backported the patch yet, you can't fix it" alerts — needs a defined triage cadence first.
- **Threat intel feed integration** (CDB lists or MISP).
- **WAF integration** (ModSecurity → ingress-nginx → Wazuh) for app-layer attacks. Better deferred until apps are actually serving real traffic.
- **EDR-class endpoint telemetry** (osquery, falco). Falco specifically catches container-runtime anomalies that auditd doesn't see; worth adding once apps go live.
- **24/7 monitoring practice** — alerts that nobody reads are not detection. The discipline of "operator reviews the feed daily, tunes noisy rules within the week, investigates true positives" is a non-technical commitment that lives in operations docs, not here.

What's in scope is **detect-the-obvious**: SSH brute force, sudo abuse, FIM violation on a privileged path, suspicious process spawn, package tamper, scanner-driven probing, configuration drift. That's most of what a small-target threat model needs.

## Verification

`platform/manifests/wazuh-host-agent/verify-detection.sh` is an attack-simulation suite that fires known attacker behaviours and asserts the corresponding Wazuh alert appears. Run it after `11b-fail2ban.sh` completes:

```bash
bash platform/manifests/wazuh-host-agent/verify-detection.sh
```

Expected: PASS on all 6 simulations within ~30 seconds. Failure modes and triage are documented in the script's header.

The script is **not** in `components/` — it's a verification tool, not part of the install path. `install-all.sh` does not run it.

## Operational notes

- **Agent version pinning** is in `11-wazuh-host-agent.sh`'s header (`AGENT_VERSION=`). Keep it within one minor of the manager's version (Phase 7 deploys 4.14.x via the vendored chart). Cross-major mismatches are unsupported.
- **Upgrade procedure** is `apt upgrade wazuh-agent` — no special steps. The systemd unit restarts automatically.
- **Key rotation:** re-run `11-wazuh-host-agent.sh`. The script detects the existing agent registration and deregisters it before re-registering, producing a fresh `client.keys`.
- **Recovery if you ban your own IP during fail2ban testing:** documented in `11b-fail2ban.sh`'s closing-message.
- **Removing the in-cluster DaemonSet manually** if `11-wazuh-host-agent.sh` skipped that step for any reason:
  ```bash
  kubectl delete -f platform/manifests/wazuh-agent/04-daemonset.yaml
  kubectl delete -f platform/manifests/wazuh-agent/03-configmap.yaml
  kubectl delete ns wazuh-agent
  ```
- **The in-cluster DaemonSet** (`platform/manifests/wazuh-agent/` + `platform/components/07b-wazuh-agent.sh`) is superseded by component 11. After 11 is verified, remove `07b-wazuh-agent.sh` from `components/` so `install-all.sh` stops re-deploying the DaemonSet on every run. (The retired local-edition copy under `infrastructure/wazuh-agent/` was removed in the 2026-05-20 retirement.)

## ADR

The decision to move from DaemonSet to native is documented in `docs/02-decisions/NNNN-wazuh-agent-native-vs-daemonset.md`. ADR slot is whatever's next free per `ls docs/02-decisions/`. The ADR captures the trade-offs, the multi-node future (one native agent per node via the same install script), and explicitly records that this is a deliberate rollback of the "everything declarative-in-k8s" pattern for the specific case where it didn't fit.
