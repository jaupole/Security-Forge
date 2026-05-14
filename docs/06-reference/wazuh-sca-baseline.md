# Wazuh SCA accepted-baseline — CIS Ubuntu 24.04 LTS

CIS Ubuntu 24.04 LTS Benchmark v1.0.0 — items that fail the SCA scan but
SHOULD remain that way on a SecForge host. Each entry has a documented
reason and (where applicable) the compensating control that achieves the
same security goal through a different mechanism.

When triaging Wazuh SCA findings on a SecForge host, suppress the IDs in
this document and review only the others.

Last reviewed: 2026-05-09 (kernel 6.17.0-23-generic, k3s v1.31.14, hardening
script `platform/components/00b-cis-hardening.sh`).

---

## Will break the stack — must remain failed

### CIS 3.3.1 (Wazuh ID 35608) — `net.ipv4.ip_forward = 0`

**Why we cannot fix:** k3s pod networking requires IP forwarding.
Disabling forwarding kills inter-pod and pod-to-service traffic; CNI
breaks; the cluster is non-functional.

**Compensating control:** Egress filtering at the Kubernetes layer via
NetworkPolicy + Istio Ambient (Layer A and Layer B in the platform plan).
Host-level UFW handles north-south (external) traffic.

---

### CIS 4.1.1 (Wazuh ID 35619), 4.4.1.3 (Wazuh ID 35635) — Single firewall utility

**Why we cannot fix:** k3s manages iptables rules for service routing
(ClusterIP, NodePort, kube-proxy). UFW is configured for host-level
ingress filtering. By definition both are active. The benchmark assumes
a single-purpose host with one firewall utility; SecForge's Kubernetes
control plane requires both.

**Compensating control:** UFW default-deny on `eno1` for all ports except
22/80/443/6443 + cni0/pod-CIDR allowances. k3s iptables rules are managed
by the kubelet and audited via Wazuh's auditd module-load monitoring.

---

### CIS 4.2.7 (Wazuh ID 35624) — UFW default deny outgoing

**Why we cannot fix:** Default-deny outgoing on the host blocks egress to
Hetzner's apt repositories, Let's Encrypt ACME endpoints, container
registries (ghcr.io, docker.io), Cloudflare DNS, Backblaze B2, and
SecForge cluster east-west traffic. Would break the box.

**Compensating control:** Egress filtering happens at the pod layer via
NetworkPolicy (Layer A) and Istio Ambient L7 policy (Layer B). The host
itself runs only k3s + node-exporter + Wazuh agent, all of which need
broad outbound for cluster operation.

---

### CIS 6.2.2.3 — `disk_full_action = halt`

**Why we cannot fix as written:** The CIS benchmark recommends `halt` as
one option. Halt = automatic shutdown when audit logs fill the disk. On
a single-node bare-metal cluster, that's a self-inflicted outage with
zero warning, masking whatever underlying issue caused the log fill.

**What we do instead:** `disk_full_action = single` (boot to single-user
mode) plus `admin_space_left_action = single` and Prometheus alerts at
60% / 85% disk utilization (`NodeDiskSpaceLow` rule in
`platform/manifests/observability/09-platform-alerts.yaml`). The CIS rule
accepts `halt` OR `single` for the audit (Wazuh ID 35729 doesn't fail on
`single`), so this is actually compliant — but documenting the choice.

---

## Architectural — deferred until next OS reinstall

### CIS 1.1.2.1.1 – 1.1.2.7.4 (Wazuh IDs 35510–35535) — Separate partitions for /tmp, /home, /var, /var/tmp, /var/log, /var/log/audit

**Why deferred:** The current installimage layout allocated everything to
the root LV plus dedicated workload LVs (`/var/lib/rancher`,
`/var/lib/cnpg`, `/var/lib/minio`, `/var/lib/wazuh`). Adding separate
LVs for `/var`, `/var/log`, `/var/log/audit`, `/tmp`, `/home`, `/var/tmp`
now requires data migration with downtime — impractical given how much
state already lives under `/var`.

**When we'll fix:** At the next OS reinstall (planned-event downtime).
The replacement `installimage` config in
`Security Forge/platform/host/installimage.conf` already specifies the
correct partition layout for a clean install.

**Compensating control:** Disk-fill alerting in Prometheus
(`NodeDiskSpaceLow` < 15%); auditd `disk_full_action = single` to fail
safely on log saturation; mount-table monitoring (gap #29 fix).

---

### CIS 1.3.1.3, 1.3.1.4 (Wazuh IDs 35538, 35539) — All AppArmor profiles enforcing

**Why deferred:** k3s containerd disables some host-level AppArmor
profiles for container runtime compatibility (notably `runc`,
`containerd`, and CNI binaries). Globally `aa-enforce /etc/apparmor.d/*`
would break container start.

**What we do:** Install AppArmor (`apparmor`, `apparmor-utils`) and
enable in the bootloader (`apparmor=1 security=apparmor`) so profiles
*can* be enforced selectively. AppArmor profiles for individual
SecForge components (Keycloak, OpenBao, etc.) are tracked separately as
a Phase 7-rest todo.

---

### CIS 1.4.1 (Wazuh ID 35540) — Bootloader password

**Why deferred:** Hetzner Robot's web console can boot the rescue system
and reset the box regardless of GRUB password. The compromise model
(physical access to a Hetzner DC) isn't blocked by a GRUB password
anyway. Adds operator friction (must type password on every reboot,
including unattended reboots after kernel updates) for marginal benefit.

**Worth revisiting:** If we ever move off Hetzner Robot.

---

### CIS 6.1.2.1.2 (Wazuh ID 35710), 6.1.3.6 (Wazuh ID 35720) — Remote rsyslog log host

**Why we don't:** SecForge ships logs to Loki via Promtail (DaemonSet in
the `observability` namespace), not via rsyslog. The control's intent —
shipping logs off-box so a compromised host can't tamper with them — is
satisfied by Loki + S3 backend (MinIO), with the same off-host integrity
guarantee.

**Compensating control:**
[platform/manifests/observability/](../../platform/manifests/observability/)
defines Promtail + Loki + the immutable MinIO log bucket.

---

### CIS 2.3.3.2, 2.3.3.3 (Wazuh IDs 35591, 35592) — chrony running

**Why we don't pass:** The benchmark's chrony checks pass only when chrony
is the active time-sync tool AND systemd-timesyncd is `not loaded` and
`not active`. SecForge uses `systemd-timesyncd` (configured via 35588)
because it's the systemd-native default, requires no extra package, and
has lower attack surface than chrony.

**Compensating control:** systemd-timesyncd is configured with explicit
NTP servers (Hetzner pool + Cloudflare/pool.ntp.org fallback) and is
covered by CIS 2.3.2.1 (Wazuh ID 35588), which we DO pass.

---

### CIS 4.3.x, 4.4.1.x, 4.4.2.x, 4.4.3.x (Wazuh IDs 35626, 35627, 35629, 35631, 35632, 35633, 35634, 35637, 35638, 35639) — nftables / iptables firewall path

**Why these fail:** The CIS Ubuntu benchmark has separate sections for
ufw (Section 4.2), nftables (Section 4.3), and iptables (Section 4.4).
Each path's checks assume that path's tool is the chosen firewall. Since
SecForge uses **ufw on the host** (Section 4.2), the nftables and
iptables sections fail by definition.

**Compensating control:** ufw section checks pass (default-deny incoming,
allow 22/80/443/6443, cni0 + pod-CIDR allowances per Gap #27). k3s
manages its own iptables rules for service routing — that's a Kubernetes
architectural requirement, not a SecForge choice.

---

### CIS 5.4.1.2, 5.4.1.3, 5.4.1.5 (Wazuh IDs 35695, 35696, 35698) — Password aging on existing users

**Why these fail:** The SCA rules require at least one user in
`/etc/shadow` with a hashed password (`$...$` format) AND the corresponding
aging field set correctly. SecForge's `ops` user is key-only (no password
set) and `root` is locked (`!` in shadow). Therefore no shadow line
matches the regex and the check fails — even though `/etc/login.defs`
has the correct policy for any future user creation.

**Compensating control:** `/etc/login.defs` is correct (PASS_MAX_DAYS=365,
PASS_MIN_DAYS=1, PASS_WARN_AGE=7), `useradd -D` shows INACTIVE=45. Any
future user with a password gets the right policy. To make these checks
pass, you'd have to set a hashed password on `ops` (intrusive — they
authenticate via SSH key only).

---

### CIS 5.3.2.4 (Wazuh ID 35675) vs 5.3.3.3.3 (Wazuh ID 35689) — Wazuh SCA rule contradiction

**The contradiction:** 35675's rule expects
`password required pam_pwhistory.so` in `/etc/pam.d/common-password`,
while 35689's rule expects
`password requisite pam_pwhistory.so` on the same line.

A single line cannot be both `required` and `requisite`. The actual CIS
benchmark text says `requisite` — so we use that, pass 35689, and accept
35675 as a Wazuh SCA bug (filed upstream).

---

### CIS 6.2.4.8 (Wazuh ID 35755) — Audit tools mode

**Why this fails:** The SCA regex marks as failed any audit-tool file with
mode matching `0xx`, `7xx` patterns including `700`, `750`, `755`. The
remediation `chmod go-w` (per CIS) leaves the default `755`, which the
regex rejects. There is no executable file mode that simultaneously
permits root execution and passes this regex pattern.

This appears to be a Wazuh SCA rule bug — the intended check ("not
world-writable") isn't what the regex actually tests. Filed upstream;
binaries remain at default `755 root:root` (no group/other write), which
satisfies CIS itself.

---

### CIS 7.1.10 (Wazuh ID 35770) — `/etc/security/opasswd` permissions

**Why this fails:** The check requires
`/etc/security/opasswd` and `/etc/security/opasswd.old` to exist with
mode 0600 root:root. These files are created **by pam_unix on the first
password change** that goes through the password-history machinery. On
SecForge, no user has ever changed a password (key-only auth), so the
files don't exist yet → check fails.

**When this resolves:** First time `passwd <user>` is run for any local
user. The 00c hardening script ensures the chmod will be correct
whenever those files appear.

---

### CIS 5.1.18 (Wazuh ID 35657) — sshd MaxStartups (dev-mode tradeoff)

**Why we don't pass:** The SCA rule requires `MaxStartups N:N:N` where the
first field ≤ 10, second ≤ 30, third ≤ 60. We run with `30:30:200` to
prevent rapid SSH bursts (e.g., from automation tooling like Claude Code
running many SSH calls in sequence) from being randomly dropped by sshd.

**Tradeoff:** A SYN-flood-style attack could now establish up to 200
unauthenticated connections instead of 60 before being throttled. Still
protected by:
- fail2ban (relaxed to 20 failures / 60s in our dev jail)
- key-only authentication (no password attempts to brute-force)
- UFW host firewall

**To restore CIS-compliance** (production-mode):
```bash
sudo sed -i 's|^MaxStartups.*|MaxStartups 10:30:60|' /etc/ssh/sshd_config.d/00-cis-hardening.conf
sudo systemctl reload ssh
```

---

### CIS 6.1.4.1 (Wazuh ID 35722) — `/var/log` permissions (SCA stale)

**Why this lingers:** All files under `/var/log` are at safe modes
(`0640`, `0600`, or `0440`) — verifiable via
`find /var/log -type f -ls` plus the SCA's own regex patterns (no file
matches the bad-perm regex). Despite this, the Wazuh SCA agent's cached
result for this check sometimes doesn't update across multiple manual
scan triggers.

**Workaround:** Eventually self-resolves on the agent's natural 12h
re-scan cycle. Forcing via `wazuh-control restart` doesn't reliably
invalidate this specific check's result.

**Compensating control:** All log files inspected and verified at
secure modes; the actual security posture is correct regardless of
what the SCA dashboard says.

---

### CIS 1.1.1.10 (Wazuh ID 35509) — Filesystem modules: `fuse` excepted

**Why fuse stays loadable:** `snapd` (Ubuntu's snap package manager) uses
the `fuse` kernel module to mount squashfs-based snap packages. Disabling
`fuse` would break snap. We blacklist all OTHER filesystem modules from
the CIS list (`afs`, `ceph`, `cifs`, `exfat`, `fscache`, `gfs2`,
`nfs_common`, `nfsd`, `smbfs_common`, `cramfs`, `freevxfs`, `jffs2`,
`hfs`, `hfsplus`, `udf`, `9p`).

**To fully fix:** Remove snapd entirely (`apt purge snapd`). Acceptable
on a server that doesn't use snap packages, but defer until we've
confirmed nothing depends on it.

## Re-evaluate periodically

### CIS 6.2.3.20 (Wazuh ID 35749) — Audit immutable mode (`-e 2`)

We **do** apply this. Note that any future audit rule changes require a
reboot to take effect (the rule set is immutable until then). Keep in
mind during incident response.

---

## Summary

After running `00b-cis-hardening.sh`, the Wazuh SCA dashboard for
`secforge-prod` should report ≤10 failed checks, all of which appear
above with documented reasons. If a previously-failing check is fixed
elsewhere in the stack, remove it from this document and re-baseline.
