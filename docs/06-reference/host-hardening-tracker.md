# Host Hardening Tracker — secforge-prod

Findings from the 2026-05-28 user-foothold audit. Source: `ops`-shell read-only enumeration; no exploits executed.

## Status legend

- [x] Applied
- [ ] Pending
- [~] Partial / verification done, change still pending

## P0 — root-equivalent paths

| # | Item | Status | Notes |
|---|---|---|---|
| 1 | Remove `NOPASSWD` from `/etc/sudoers.d/90-ops`; add narrow `NOPASSWD` entries only for specific automation paths | [ ] | **Coordinate.** Sequence after #4. Inspect every `sudo -n` callsite in `platform/components/*.sh` + GHA workflows first. |
| 2 | Move SSH to Tailscale-only (`ufw delete allow 22/tcp` v4+v6; `ufw allow in on tailscale0 to any port 22`) | [ ] | **Verify first.** Confirm `tailscale status` on workstation reaches the box; leave both rules live for 24h before removing public. |
| 3 | `chown root:root /usr/local/bin/cosign && chmod 755` | [x] | Closes ops-writable supply-chain persistence vector. |
| 4 | Strip cluster-admin from ops kubeconfig; keep admin in `/root/.kube/config` accessed via `sudo kubectl` | [ ] | **Coordinate.** Define `secforge-ops` ClusterRole (admin minus `delete namespaces`, minus exec into openbao/keycloak/postgres). Audit `.github/workflows/**.yaml` for ops-kubeconfig usage. |

## P1 — material disclosure / attack-path enablement

| # | Item | Status | Notes |
|---|---|---|---|
| 5 | Auto-clean `/tmp/*.{pem,crt,key,*backup.yaml,*.diff}` after 24h; manual one-time clean of existing leftovers | [x] | Implemented as `/etc/cron.daily/secforge-tmp-cleanup` (NOT tmpfiles.d — the `e` type doesn't accept glob argument fields, lines were silently ignored). Cron.daily uses `find -mtime +0 -delete`. 15 files removed in one-time pass including the `openbao-seal-block.backup.yaml` from earlier rotation work. |
| 6 | `HISTIGNORE` + `HISTCONTROL=ignorespace` in `~/.bashrc`; rewrite GHCR rotation flow to read PAT from sealed source, not stdin | [~] | `.bashrc` updated. GHCR rotation script rewrite still pending — no script file exists today (heredoc in history); convert to `~/secforge/platform/components/rotate-ghcr-pat.sh`. |
| 7 | Verify AIDE covers `/usr/local/bin` + `~ops/.ssh/authorized_keys`; if missing, add | [x] | `/etc/aide/aide.conf.d/50_aide_secforge_hardening` installed; database re-init triggered (runs in background, ~5 min). |
| 8 | Passphrase-protect `~/.ssh/id_ed25519_secforge_deploy`; load via `ssh-agent` with `AddKeysToAgent confirm` | [ ] | **Verify first.** Check `crontab -l`, `sudo crontab -l`, all timers for git-pull usage. If clean, apply. |
| 9 | `sshd_config`: `X11Forwarding no` (✓ already in `99-secforge-hardening.conf`), `AddressFamily inet` | [x] | Two changes needed: (a) `AddressFamily inet` appended to `99-secforge-hardening.conf`; (b) Ubuntu uses `ssh.socket` activation so sshd inherits FDs and `AddressFamily` alone is ignored — added `/etc/systemd/system/ssh.socket.d/no-ipv6.conf` overriding `ListenStream=` to clear inherited list, then `ListenStream=0.0.0.0:22`. After `systemctl daemon-reload && restart ssh.socket ssh.service`, only `0.0.0.0:22` is bound. v6 SSH gone. |

## P2 — hardening gaps

| # | Item | Status | Notes |
|---|---|---|---|
| 10 | Sandbox self-hosted GHA runners (ephemeral DinD per job) or restrict via branch-protection + required reviews on workflow files | [ ] | **Coordinate (multi-day project).** Near-term cheaper mitigation: require code review for any `.github/workflows/**.yaml` change. |
| 11 | Bind `node_exporter` to cni0 (`10.42.0.1:9100`), narrow `spire-agent:9982` | [ ] | **Verify first.** Inspect Prometheus scrape config + SPIRE pod connectivity. Likely needs cni0 bind, NOT localhost. |
| 12 | Disable + remove `secforge-temp-admin-cleanup.timer` (self-disabled 2026-05-21 already) | [x] | Unit files removed; daemon-reload done. |
| 13 | BIOS update via `fwupdmgr` (ASUS Pro WS 665-ACE, firmware 2023-10-06) | [ ] | **Downtime required** (~10–20 min single-node outage). Velero backup + low-traffic window. |

## Out-of-band defensive observations (already working)

- PermitRootLogin no, PasswordAuthentication no, MaxAuthTries 3, ClientAliveInterval 300
- UFW default-deny incoming with explicit allow-list
- k3s API closed publicly (per `project_hetzner_idp_hardening_state`)
- Kyverno Enforce mode for `require-run-as-nonroot` + `disallow-latest-tag` + `pss-baseline`
- Wazuh agent active and reporting (16h uptime as of audit)
- AIDE daily check via timer
- fail2ban active on SSH
- sudo logged to `/var/log/sudo.log`
- etcd-at-rest encryption enabled (per `project_encryption_architecture`)
- Tailscale operator-access mesh present
- Single SSH key authorized (`jaupole@googlemail.com`)

## Sequencing decisions (2026-05-28)

- **Do #2 (Tailscale-only SSH) before deciding on #1 + #4.** Once public `:22` is closed, the attack model that #1 defends against (stolen SSH key → internet brute-force → escalate via NOPASSWD) requires the attacker to first compromise a Tailnet-authorized device — at which point they have the operator's workstation and can keylog the sudo password anyway. For a solo operator, perimeter > internal privilege separation. Re-evaluate #1 + #4 after #2 lands.
- **Skipped: separate `claude-bot` SSH account.** Considered as a way to keep narrow-NOPASSWD scope for automated diagnostics while making `ops` sudo password-required. Concluded the audit-trail and blast-radius benefits are weak for a solo operator once #2 is in place; not worth the two-account overhead.
- **Investment pivot.** With #2 done, leverage moves to workstation hardening: SSH key passphrase, hardware-key auth (Yubikey / Secure Enclave), Tailscale ACL restricting `:22` reachability to the specific operator device. These are higher-yield than further sudoers segmentation on the box.

## Audit artifacts

- `/tmp/openbao-seal-block.backup.yaml` (today 02:48) — **removed** as part of #5
- `~/keycloak-cr-rollback-20260522-*.yaml` (×3) — left in place; recommend rotating to `/var/lib/secforge-rollbacks/` with `chmod 600` + tmpfiles cleanup policy
- Stray `~/=` and `~/027` zero-byte typo artifacts — recommend `rm`
- `linux-image-6.17.0-23-generic` lingering alongside running `-29-generic` — apt autoremove on next maintenance window
