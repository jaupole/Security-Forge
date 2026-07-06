#!/usr/bin/env bash
# 00 — Host bootstrap. Run-once-per-host idempotent setup that handles:
#
#   1. Kernel sysctl hardening (info leaks, network hardening, BPF, FS)
#   2. fs.inotify limits bumped for Promtail (was: ad-hoc fix in Phase 7)
#   3. ufw rules (default-deny incoming + 22/80/443 allow)
#   4. unattended-upgrades for security-only auto-patching
#   5. /etc/rancher/k3s/audit-policy.yaml + config.yaml placement
#      (k3s API audit log enabled; restart applied if config changed)
#
# This script encodes the host-level setup that was previously implicit
# (done by hand during Phase A of the original migration). Re-running on
# a fresh host reproduces the same state.
#
# MUST be run as root (uses systemctl + sysctl + ufw + apt).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: must run as root (uses systemctl + sysctl + ufw + apt)" >&2
  exit 1
fi

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# ─── 1. Kernel sysctl hardening ───────────────────────────────────────
green "==> install /etc/sysctl.d/99-secforge-hardening.conf"
install -m 0644 -o root -g root \
    "$PLATFORM_DIR/host/sysctl/99-secforge-hardening.conf" \
    /etc/sysctl.d/99-secforge-hardening.conf

green "==> install /etc/sysctl.d/91-k3s-kubelet.conf"
# Required for k3s kubelet --protect-kernel-defaults. New HWE kernels reset
# these on upgrade reboot; persisting here keeps k3s booting cleanly. Discovered
# 2026-05-19 when 6.17.0-23 → 29 left k3s in crash-loop.
install -m 0644 -o root -g root \
    "$PLATFORM_DIR/host/sysctl/91-k3s-kubelet.conf" \
    /etc/sysctl.d/91-k3s-kubelet.conf

# ─── 2. inotify limits + mount table ceiling ──────────────────────────
green "==> install /etc/sysctl.d/90-secforge-limits.conf"
cat > /etc/sysctl.d/90-secforge-limits.conf <<'EOF'
# Promtail tails /var/log/pods/* across the entire SecForge pod set.
# Default 128 instances is too low; default 524288 watches is OK.
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# Kernel mount table limit. Ubuntu 24.04 default is 100,000. SecForge
# generates ~1,000–2,000 mounts/pod (projected volumes, secrets, CSI),
# and stale entries accumulate if pods exit uncleanly. At 100k the
# SPIFFE CSI driver fails with ENOSPC (MS_BIND|MS_REC), causing stuck-
# terminating pods and cascading platform failures (incident 2026-05-09).
# 1M gives ~40 years of headroom at current growth rate.
fs.mount-max = 1048576
EOF
# Remove old filename if it exists from earlier bootstrap runs
rm -f /etc/sysctl.d/90-inotify.conf

green "==> sysctl --system (apply both)"
sysctl --system | tail -5

# ─── 3. ufw — default-deny incoming + SSH/HTTP/HTTPS ──────────────────
green "==> ufw configuration"
if ! command -v ufw >/dev/null 2>&1; then
  apt-get install -y ufw
fi

# Idempotent: ufw deduplicates identical rules.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP redirect'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 6443/tcp comment 'k3s API server (external)'

# Pod → host API server via cni0 bridge (Gap #27 in deployment plan).
# "ufw allow 6443" only applies to eno1; pod traffic comes in via cni0.
# Required for OpenBao Kubernetes auth method TokenReview calls.
ufw allow in on cni0 to any port 6443 proto tcp comment 'k3s API from pods'
ufw allow from 10.42.0.0/16 to any port 6443 proto tcp comment 'k3s API from pod CIDR'

# Loopback ALLOW + spoofing DENY (CIS 4.2.4 / Wazuh SCA 35623)
ufw allow in on lo
ufw allow out on lo
ufw deny in from 127.0.0.0/8
ufw deny in from ::1

# Note: ufw NodePort rules for K8s NodePorts (e.g., 31514/31515 for
# wazuh-manager-agents) are deliberately NOT added at the host level;
# those NodePorts are reachable from the node's loopback only by virtue
# of being unset in ufw — the default-deny keeps them off the public
# interface.

if ! ufw status | head -1 | grep -q active; then
  yellow "    enabling ufw (may briefly drop existing connections)"
  ufw --force enable
fi

# ─── 4. unattended-upgrades — security-only auto-patches ──────────────
green "==> unattended-upgrades for security archive"
if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
  apt-get install -y unattended-upgrades
fi

cat > /etc/apt/apt.conf.d/52unattended-upgrades-secforge <<'EOF'
// SecForge: auto-apply security archive ONLY. Don't auto-reboot.
// Operator handles k3s/host updates; this is the CVE-patch baseline.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# ─── 5. Kernel module blacklist (attack-surface reduction) ────────────
# Three-layer defense (kmod-31's `install /bin/false` falls through to
# insmod on its own, so we do all three):
#   a) Rename the .ko files → modprobe can't find them
#   b) /etc/modprobe.d/secforge-blacklist.conf with install + blacklist
#   c) module_blacklist= on the kernel command line (next-boot enforcement)
#
# Without (a), kmod-31 silently bypasses (b) for some modules (notably ksmbd
# — verified 2026-05-09). Without (c), a kernel that's been live-mutated
# (rmmod blacklist, modprobe foo) loses the blacklist on the next request.

green "==> install /etc/modprobe.d/secforge-blacklist.conf"
install -m 0644 -o root -g root \
    "$PLATFORM_DIR/host/modprobe.d/secforge-blacklist.conf" \
    /etc/modprobe.d/secforge-blacklist.conf

# Layer A: rename .ko files for the running kernel. Idempotent.
green "==> rename .ko files for blacklisted modules"
KVER="$(uname -r)"
MODULES_TO_DISABLE='ksmbd cifs nfsd nfsv4 nfsv3 nfs lockd nfs_acl rpcsec_gss_krb5 nvmet nvmet_tcp nvmet_fc nvmet_rdma nvme_tcp nvme_fc nvme_rdma nvme_fabrics dvb_core dvb_net dvb_usb dvb_usb_v2 dvb_pll smc smc_diag nf_conntrack_h323 nf_conntrack_sane nf_conntrack_amanda nf_conntrack_irc nf_conntrack_netbios_ns nf_conntrack_pptp nf_conntrack_snmp nf_conntrack_tftp sctp dccp rds rds_tcp rds_rdma tipc ax25 netrom rose decnet x25 appletalk ipx n_hdlc cramfs freevxfs jffs2 hfs hfsplus udf 9p usb_storage firewire_core firewire_ohci'
renamed=0
for mod in $MODULES_TO_DISABLE; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [[ "$f" != *.secforge-disabled ]]; then
      chmod 0644 "$f" 2>/dev/null  # in case prior runs chmod'd to 0
      mv "$f" "$f.secforge-disabled"
      renamed=$((renamed+1))
    fi
  done < <(find "/lib/modules/$KVER" -name "$mod.ko*" 2>/dev/null)
done
yellow "    renamed $renamed module files to *.secforge-disabled"
depmod -a "$KVER"

# Layer C: kernel-level module_blacklist= (enforced at boot).
green "==> add module_blacklist= to GRUB kernel command line"
BLACKLIST_KEY='ksmbd,cifs,nfsd,nfsv4,nfsv3,nfs,lockd,nvmet,nvmet_tcp,nvme_tcp,nvme_fabrics,dvb_core,dvb_net,smc,smc_diag,sctp,dccp,rds,tipc,ax25,n_hdlc,cramfs,freevxfs,jffs2,hfs,hfsplus,udf,9p,usb_storage,firewire_core,nf_conntrack_h323,nf_conntrack_sane'
if grep -q 'module_blacklist=' /etc/default/grub; then
  sed -i "s|module_blacklist=[^ \"]*|module_blacklist=$BLACKLIST_KEY|" /etc/default/grub
else
  sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 module_blacklist=$BLACKLIST_KEY\"|" /etc/default/grub
fi
update-grub >/dev/null
update-initramfs -u >/dev/null

# Unload any blacklisted modules currently in memory (idempotent re-run).
for mod in $MODULES_TO_DISABLE; do
  if lsmod | grep -q "^$mod "; then
    yellow "    unloading already-loaded module: $mod"
    modprobe -r "$mod" 2>/dev/null || yellow "      (in use; will unload at next reboot)"
  fi
done

# ─── 6. Mount-count textfile exporter for node-exporter ───────────────
green "==> mount-count-exporter (node-exporter textfile metric)"
install -m 0755 -o root -g root \
    "$PLATFORM_DIR/host/node-exporter/mount-count-exporter.sh" \
    /usr/local/sbin/mount-count-exporter.sh

for unit in mount-count-exporter.service mount-count-exporter.timer; do
  install -m 0644 -o root -g root \
      "$PLATFORM_DIR/host/node-exporter/$unit" \
      "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now mount-count-exporter.timer
systemctl start mount-count-exporter.service  # fire once immediately

mkdir -p /var/lib/node_exporter/textfile_collector

# ─── 6b. Repo-vs-live drift check (merge-without-apply detector) ───────
green "==> k8s-drift-check (daily repo-vs-live diff, textfile metric)"
install -m 0755 -o root -g root \
    "$PLATFORM_DIR/host/drift-check/k8s-drift-check.sh" \
    /usr/local/sbin/k8s-drift-check.sh

for unit in k8s-drift-check.service k8s-drift-check.timer; do
  install -m 0644 -o root -g root \
      "$PLATFORM_DIR/host/drift-check/$unit" \
      "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now k8s-drift-check.timer

# ─── 7. k3s audit policy + config ─────────────────────────────────────
green "==> k3s audit policy + config (idempotent — restarts k3s only on diff)"
mkdir -p /etc/rancher/k3s
NEED_RESTART=0

for f in audit-policy.yaml config.yaml; do
  src="$PLATFORM_DIR/host/k3s/$f"
  dst="/etc/rancher/k3s/$f"
  if [ ! -e "$dst" ] || ! cmp -s "$src" "$dst"; then
    install -m 0600 -o root -g root "$src" "$dst"
    NEED_RESTART=1
    green "    updated $dst"
  else
    yellow "    $dst unchanged"
  fi
done

if [ "$NEED_RESTART" -eq 1 ]; then
  green "==> restarting k3s to load new audit config"
  systemctl restart k3s
  for i in $(seq 1 24); do
    if kubectl get --raw /readyz >/dev/null 2>&1; then
      green "    k3s ready"
      break
    fi
    sleep 5
  done
else
  yellow "    k3s config unchanged; no restart"
fi

cat <<EOF

✓ Host bootstrap complete.

Settings active:
  - sysctl hardening:        /etc/sysctl.d/99-secforge-hardening.conf
  - k3s kubelet sysctls:     /etc/sysctl.d/91-k3s-kubelet.conf
                             (vm.overcommit_memory=1, kernel.panic=10, kernel.panic_on_oops=1)
  - inotify + mount limits:  /etc/sysctl.d/90-secforge-limits.conf
                             (fs.inotify.max_user_instances=8192, fs.mount-max=1048576)
  - ufw default-deny:        enabled, 22/80/443/6443 open + cni0/pod-CIDR rules
  - unattended-upgrades:     security-only, no auto-reboot
  - k3s API audit:           /var/log/k3s-audit.log (json)

Verify:
  sysctl kernel.dmesg_restrict kernel.kptr_restrict net.ipv4.conf.all.rp_filter
  sysctl fs.mount-max fs.inotify.max_user_instances
  ufw status verbose
  systemctl is-active unattended-upgrades
  ls -la /var/log/k3s-audit.log
EOF
