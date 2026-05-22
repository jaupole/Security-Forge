#!/usr/bin/env bash
# 00b — CIS Ubuntu 24.04 LTS Benchmark hardening (Wazuh SCA findings).
#
# Addresses ~75 of the 127 failed checks from the first SCA scan. Skipped
# checks are documented with rationale in:
#   docs/06-reference/wazuh-sca-baseline.md
#
# Run order: after 00-host-bootstrap.sh, before any cluster components.
# Idempotent — safe to re-run.
#
# MUST be run as root.
#
# Sections:
#   1. Filesystem module blacklist (extends secforge-blacklist.conf)
#   2. Banners (/etc/issue, /etc/issue.net)
#   3. Misc host hardening (sysctl, core dumps, apport, telnet, sudo log)
#   4. Time sync (systemd-timesyncd with explicit NTP servers)
#   5. AppArmor (install + enable in bootloader, do NOT enforce-all)
#   6. Cron / at access control
#   7. SSH hardening (sshd_config + permissions)
#   8. PAM stack (libpam-pwquality, faillock, pwhistory, pwquality)
#   9. login.defs password aging + chage existing users
#  10. Audit subsystem (auditd rules + config)
#  11. Logging hardening (journald rotation, rsyslog perms, /var/log)
#  12. AIDE (filesystem integrity)
#  13. /etc/security/opasswd permissions

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. Filesystem module blacklist ───────────────────────────────────
green "==> [1/13] reinstall secforge-blacklist.conf (now with filesystem modules)"
install -m 0644 -o root -g root \
    "$PLATFORM_DIR/host/modprobe.d/secforge-blacklist.conf" \
    /etc/modprobe.d/secforge-blacklist.conf
KVER="$(uname -r)"
NEW_FS_MODULES='afs ceph exfat fscache gfs2 nfs_common smbfs_common'
for mod in $NEW_FS_MODULES; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [[ "$f" != *.secforge-disabled ]]; then
      mv "$f" "$f.secforge-disabled" 2>/dev/null || true
    fi
  done < <(find "/lib/modules/$KVER" -name "$mod.ko*" 2>/dev/null)
done
depmod -a "$KVER"

# ─── 2. Banners ───────────────────────────────────────────────────────
green "==> [2/13] /etc/issue and /etc/issue.net banners"
BANNER='Authorized users only. All activity may be monitored and reported.'
printf '%s\n' "$BANNER" > /etc/issue
printf '%s\n' "$BANNER" > /etc/issue.net
chmod 0644 /etc/issue /etc/issue.net

# ─── 3. Misc host hardening ───────────────────────────────────────────
green "==> [3/13] core dumps, apport, telnet, sysctls, sudo log, su restrict, root umask, TMOUT"

# Core dumps off (CIS 1.5.3)
cat > /etc/sysctl.d/60-cis-coredump.conf <<'EOF'
fs.suid_dumpable = 0
EOF
cat > /etc/security/limits.d/60-cis-coredump.conf <<'EOF'
* hard core 0
EOF

# Network sysctl hardening (CIS 3.3.6, 3.3.9)
cat > /etc/sysctl.d/60-cis-network.conf <<'EOF'
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

sysctl --system >/dev/null
# `sysctl --system` doesn't always override existing per-interface settings
# (k3s creates many veths before this runs). Force runtime values to match
# config so the SCA check sees the live value as 1, not 0.
sysctl -w net.ipv4.conf.all.log_martians=1 >/dev/null
sysctl -w net.ipv4.conf.default.log_martians=1 >/dev/null
sysctl -w net.ipv4.conf.all.secure_redirects=0 >/dev/null
sysctl -w net.ipv4.conf.default.secure_redirects=0 >/dev/null

# Apport off (CIS 1.5.5) — purge entirely. (Mask alone leaves systemctl
# is-enabled returning `masked`, which the SCA check rejects; only
# `disabled` or `not-found` pass. Purging gives `not-found`.)
systemctl stop apport.service 2>/dev/null || true
systemctl unmask apport.service 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y apport apport-symptoms python3-apport 2>&1 | tail -2 || true

# Telnet client out (CIS 2.2.4)
DEBIAN_FRONTEND=noninteractive apt-get purge -y telnet inetutils-telnet 2>/dev/null || true

# rsync.service masked (CIS 2.1.13) — keep client tool, kill daemon
systemctl stop rsync.service 2>/dev/null || true
systemctl mask rsync.service 2>/dev/null || true

# sudo logfile (CIS 5.2.3) — Wazuh SCA's directory pattern d:/etc/sudoers.d -> \.*
# only matches files starting with a dot (regex bug), so the sudoers.d entry
# alone never satisfies the check. We write to BOTH the drop-in (real fix)
# AND /etc/sudoers main file (to satisfy the SCA regex).
cat > /etc/sudoers.d/00-cis-logfile <<'EOF'
Defaults	logfile=/var/log/sudo.log
EOF
chmod 0440 /etc/sudoers.d/00-cis-logfile
chown root:root /etc/sudoers.d/00-cis-logfile
visudo -cf /etc/sudoers.d/00-cis-logfile

if ! grep -q '^Defaults.*logfile=' /etc/sudoers; then
  echo 'Defaults	logfile=/var/log/sudo.log' | EDITOR='tee -a' visudo
fi

touch /var/log/sudo.log
chmod 0600 /var/log/sudo.log
chown root:root /var/log/sudo.log

# Restrict su (CIS 5.2.7) — only members of sugroup may su
getent group sugroup >/dev/null 2>&1 || groupadd sugroup
if ! grep -Pq '^auth\s+required\s+pam_wheel\.so.*group=sugroup' /etc/pam.d/su; then
  sed -i '/^# auth\s\+required\s\+pam_wheel\.so/a auth       required   pam_wheel.so use_uid group=sugroup' /etc/pam.d/su
  grep -q 'pam_wheel.so use_uid group=sugroup' /etc/pam.d/su || \
    echo 'auth       required   pam_wheel.so use_uid group=sugroup' >> /etc/pam.d/su
fi

# Root umask (CIS 5.4.2.6) — set 0027 in root's bash_profile and bashrc
for f in /root/.bash_profile /root/.bashrc; do
  [ -f "$f" ] || touch "$f"
  if grep -q '^umask' "$f"; then
    sed -i 's/^umask.*/umask 0027/' "$f"
  else
    echo 'umask 0027' >> "$f"
  fi
done

# TMOUT for shells (CIS 5.4.3.2) — 900 seconds idle = logout
cat > /etc/profile.d/60-cis-tmout.sh <<'EOF'
readonly TMOUT=900 ; export TMOUT
EOF
chmod 0644 /etc/profile.d/60-cis-tmout.sh

# ─── 4. Time sync ─────────────────────────────────────────────────────
green "==> [4/13] systemd-timesyncd with Hetzner NTP servers"
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/60-cis-ntp.conf <<'EOF'
[Time]
NTP=ntp1.hetzner.de ntp2.hetzner.com ntp3.hetzner.net
FallbackNTP=time.cloudflare.com pool.ntp.org
EOF
systemctl restart systemd-timesyncd 2>/dev/null || true

# ─── 5. AppArmor + GRUB kernel cmdline + kernel module rename ────────
green "==> [5/13] AppArmor install + GRUB cmdline + module rename"
DEBIAN_FRONTEND=noninteractive apt-get install -y apparmor apparmor-utils 2>&1 | tail -2
# Note: NOT running aa-enforce /etc/apparmor.d/* — would break k3s containerd

# IMPORTANT: Hetzner installimage drops /etc/default/grub.d/hetzner.cfg which
# sets GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0", and is loaded AFTER
# /etc/default/grub during update-grub — so any direct edit to /etc/default/grub
# gets clobbered. Instead, drop a zz-prefixed file under grub.d/ that loads
# last alphabetically and APPENDS via ${GRUB_CMDLINE_LINUX_DEFAULT}.
BLACKLIST_KEY='ksmbd,cifs,nfsd,nfsv4,nfsv3,nfs,lockd,nvmet,nvmet_tcp,nvme_tcp,nvme_fabrics,dvb_core,dvb_net,smc,smc_diag,sctp,dccp,rds,tipc,ax25,n_hdlc,cramfs,freevxfs,jffs2,hfs,hfsplus,udf,9p,usb_storage,firewire_core,nf_conntrack_h323,nf_conntrack_sane'
cat > /etc/default/grub.d/zz-secforge.cfg <<EOF
# SecForge CIS hardening params, loaded after Hetzner's hetzner.cfg.
# Appends to whatever GRUB_CMDLINE_LINUX_DEFAULT was set previously.
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} module_blacklist=$BLACKLIST_KEY apparmor=1 security=apparmor audit=1 audit_backlog_limit=8192"
EOF

# Rename .ko files for ALL blacklisted modules (filesystem + niche-protocol +
# vulnerable-subsystem). modprobe install /bin/false isn't reliable on kmod
# v31 (silently bypassed for some modules), so the rename is the real fix.
ALL_BLACKLISTED='ksmbd cifs smbfs_common afs ceph exfat fscache gfs2 nfs_common nfsd nfsv4 nfsv3 nfs lockd nfs_acl rpcsec_gss_krb5 nvmet nvmet_tcp nvmet_fc nvmet_rdma nvme_tcp nvme_fc nvme_rdma nvme_fabrics dvb_core dvb_net dvb_usb dvb_usb_v2 dvb_pll smc smc_diag nf_conntrack_h323 nf_conntrack_sane nf_conntrack_amanda nf_conntrack_irc nf_conntrack_netbios_ns nf_conntrack_pptp nf_conntrack_snmp nf_conntrack_tftp sctp dccp rds rds_tcp rds_rdma tipc ax25 netrom rose decnet x25 appletalk ipx n_hdlc cramfs freevxfs jffs2 hfs hfsplus udf 9p usb_storage firewire_core firewire_ohci'
KVER="$(uname -r)"
renamed=0
for mod in $ALL_BLACKLISTED; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [[ "$f" != *.secforge-disabled ]]; then
      mv "$f" "$f.secforge-disabled" 2>/dev/null && renamed=$((renamed+1))
    fi
  done < <(find "/lib/modules/$KVER" -name "$mod.ko*" 2>/dev/null)
done
yellow "    renamed $renamed module files to *.secforge-disabled"
depmod -a "$KVER"

update-grub >/dev/null
update-initramfs -u >/dev/null

# ─── 6. Cron / at access control ──────────────────────────────────────
green "==> [6/13] cron + at file permissions and access control"
chmod og-rwx /etc/crontab 2>/dev/null || true
chown root:root /etc/crontab 2>/dev/null || true
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d; do
  if [ -d "$d" ]; then
    chmod og-rwx "$d"
    chown root:root "$d"
  fi
done

# /etc/cron.allow (CIS 2.4.1.8) — Wazuh SCA strictly requires root:root
# (NOT the CIS-recommended root:crontab). Pick the SCA-compatible one;
# crontab tool is setgid `crontab` and won't be able to read this when
# user-perms-only — but on a single-operator box without user crontabs
# that's fine.
[ -f /etc/cron.allow ] || touch /etc/cron.allow
chmod 0640 /etc/cron.allow
chown root:root /etc/cron.allow

# /etc/at.allow (CIS 2.4.2.1) — same pattern for at
if dpkg -l at >/dev/null 2>&1; then
  touch /etc/at.allow
  chmod 0640 /etc/at.allow
  if getent group daemon >/dev/null; then
    chown root:daemon /etc/at.allow
  else
    chown root:root /etc/at.allow
  fi
fi

# ─── 7. SSH hardening ─────────────────────────────────────────────────
green "==> [7/13] SSH hardening (sshd_config drop-in)"

# Permissions on sshd_config (CIS 5.1.1)
chmod 0600 /etc/ssh/sshd_config
chown root:root /etc/ssh/sshd_config
if [ -d /etc/ssh/sshd_config.d ]; then
  find /etc/ssh/sshd_config.d -type f -exec chmod 0600 {} +
  find /etc/ssh/sshd_config.d -type f -exec chown root:root {} +
fi

# Drop-in with hardened settings
cat > /etc/ssh/sshd_config.d/00-cis-hardening.conf <<'EOF'
# CIS Ubuntu 24.04 SSH hardening — applied by 00b-cis-hardening.sh
Banner /etc/issue.net
DisableForwarding yes
MaxStartups 10:30:60
MACs -hmac-md5,hmac-md5-96,hmac-ripemd160,hmac-sha1-96,umac-64@openssh.com,hmac-md5-etm@openssh.com,hmac-md5-96-etm@openssh.com,hmac-ripemd160-etm@openssh.com,hmac-sha1-96-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com
EOF
chmod 0600 /etc/ssh/sshd_config.d/00-cis-hardening.conf

# AllowGroups + PermitRootLogin no — only flip if `ops` user is set up safely
OPS_READY=1
if ! id ops >/dev/null 2>&1; then
  yellow "    SKIP PermitRootLogin=no: 'ops' user does not exist"
  OPS_READY=0
elif ! id -nG ops | tr ' ' '\n' | grep -qx sudo; then
  yellow "    SKIP PermitRootLogin=no: 'ops' is not in sudo group"
  OPS_READY=0
elif [ ! -s /home/ops/.ssh/authorized_keys ]; then
  yellow "    SKIP PermitRootLogin=no: /home/ops/.ssh/authorized_keys empty"
  OPS_READY=0
fi

if [ "$OPS_READY" = "1" ]; then
  cat > /etc/ssh/sshd_config.d/01-cis-access.conf <<'EOF'
# Locks out root SSH; only sudo group members may log in.
# Ensure your operator key is in /home/ops/.ssh/authorized_keys before this!
PermitRootLogin no
AllowGroups sudo
EOF
  chmod 0600 /etc/ssh/sshd_config.d/01-cis-access.conf

  # Wazuh SCA explicitly checks /etc/ssh/sshd_config (not the drop-in).
  # Also write to the main file so the SCA check passes.
  if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin no|' /etc/ssh/sshd_config
  else
    echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
  fi
  green "    PermitRootLogin=no + AllowGroups=sudo applied"
fi

# Validate config before reload
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  red "    sshd config validation FAILED — not reloading"
  rm -f /etc/ssh/sshd_config.d/01-cis-access.conf
fi

# ─── 8. PAM stack ─────────────────────────────────────────────────────
green "==> [8/13] PAM hardening (faillock, pwhistory, pwquality, pwunix)"
DEBIAN_FRONTEND=noninteractive apt-get install -y libpam-pwquality 2>&1 | tail -2

# faillock.conf (CIS 5.3.3.1.1, 5.3.3.1.2, 5.3.3.1.3)
cat > /etc/security/faillock.conf <<'EOF'
deny = 5
unlock_time = 900
even_deny_root
EOF
chmod 0644 /etc/security/faillock.conf

# pwquality.conf — strong password rules
cat > /etc/security/pwquality.conf <<'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
difok = 5
EOF
chmod 0644 /etc/security/pwquality.conf

# pam-auth-update profiles
cat > /usr/share/pam-configs/secforge-faillock <<'EOF'
Name: Enable pam_faillock to deny access
Default: yes
Priority: 0
Auth-Type: Primary
Auth:
        [default=die]   pam_faillock.so authfail
EOF

cat > /usr/share/pam-configs/secforge-faillock-notify <<'EOF'
Name: Notify of failed login attempts and reset count upon success
Default: yes
Priority: 1024
Auth-Type: Primary
Auth:
        requisite       pam_faillock.so preauth
Account-Type: Primary
Account:
        required        pam_faillock.so
EOF

cat > /usr/share/pam-configs/secforge-pwhistory <<'EOF'
Name: pwhistory password history checking
Default: yes
Priority: 1024
Password-Type: Primary
Password:
        requisite       pam_pwhistory.so remember=24 enforce_for_root try_first_pass use_authtok
EOF

# Edit the system-shipped unix profile to remove nullok and add use_authtok
# (CIS 5.3.3.4.1, 5.3.3.4.4)
if [ -f /usr/share/pam-configs/unix ]; then
  sed -i 's/\bnullok\b//g' /usr/share/pam-configs/unix
  # Ensure use_authtok is on the Password: line (not Password-Initial:)
  if ! awk '/^Password:/{getline; print}' /usr/share/pam-configs/unix | grep -q use_authtok; then
    sed -i '/^Password:$/{n;s|$| use_authtok|}' /usr/share/pam-configs/unix
  fi
fi

# Enable all profiles non-interactively
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable secforge-faillock 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable secforge-faillock-notify 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable secforge-pwhistory 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwquality 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable unix 2>/dev/null || true

# ─── 9. login.defs + chage existing users ─────────────────────────────
green "==> [9/13] password aging policy (login.defs + chage)"
sed -i 's/^PASS_MAX_DAYS\s.*/PASS_MAX_DAYS\t365/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS\s.*/PASS_MIN_DAYS\t1/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE\s.*/PASS_WARN_AGE\t7/' /etc/login.defs

# useradd default INACTIVE = 45
useradd -D -f 45

# Apply to existing users with passwords
awk -F: '($2~/^\$.+\$/) {print $1}' /etc/shadow | while read -r u; do
  chage --maxdays 365 --mindays 1 --warndays 7 --inactive 45 "$u" 2>/dev/null || true
done

# ─── 10. Audit subsystem ──────────────────────────────────────────────
green "==> [10/13] auditd rules + config"
DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins 2>&1 | tail -2

# auditd.conf — keep logs forever, single-user mode on disk full/error
sed -i 's|^max_log_file_action\s*=.*|max_log_file_action = keep_logs|' /etc/audit/auditd.conf
sed -i 's|^space_left_action\s*=.*|space_left_action = email|' /etc/audit/auditd.conf
sed -i 's|^admin_space_left_action\s*=.*|admin_space_left_action = single|' /etc/audit/auditd.conf
sed -i 's|^disk_full_action\s*=.*|disk_full_action = single|' /etc/audit/auditd.conf
sed -i 's|^disk_error_action\s*=.*|disk_error_action = single|' /etc/audit/auditd.conf

# audit=1 + audit_backlog_limit=8192 in GRUB — handled in step 7 below.

# Audit rules — drop the entire CIS-recommended rule set into /etc/audit/rules.d/
UID_MIN="$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs)"
[ -z "$UID_MIN" ] && UID_MIN=1000

cat > /etc/audit/rules.d/50-time-change.rules <<EOF
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b64 -S clock_settime -F a0=0x0 -k time-change
-a always,exit -F arch=b32 -S clock_settime -F a0=0x0 -k time-change
-w /etc/localtime -p wa -k time-change
EOF

cat > /etc/audit/rules.d/50-system_locale.rules <<EOF
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/networks -p wa -k system-locale
-w /etc/network/ -p wa -k system-locale
-w /etc/netplan/ -p wa -k system-locale
EOF

cat > /etc/audit/rules.d/50-access.rules <<EOF
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=$UID_MIN -F auid!=unset -k access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=$UID_MIN -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=$UID_MIN -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=$UID_MIN -F auid!=unset -k access
EOF

cat > /etc/audit/rules.d/50-identity.rules <<EOF
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/nsswitch.conf -p wa -k identity
-w /etc/pam.conf -p wa -k identity
-w /etc/pam.d -p wa -k identity
EOF

cat > /etc/audit/rules.d/50-perm_mod.rules <<EOF
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
-a always,exit -F arch=b32 -S lchown,fchown,chown,fchownat -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=$UID_MIN -F auid!=unset -F key=perm_mod
EOF

cat > /etc/audit/rules.d/50-mounts.rules <<EOF
-a always,exit -F arch=b64 -S mount -F auid>=$UID_MIN -F auid!=unset -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=$UID_MIN -F auid!=unset -k mounts
EOF

cat > /etc/audit/rules.d/50-session.rules <<EOF
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
EOF

cat > /etc/audit/rules.d/50-delete.rules <<EOF
-a always,exit -F arch=b64 -S rename,unlink,unlinkat,renameat -F auid>=$UID_MIN -F auid!=unset -F key=delete
-a always,exit -F arch=b32 -S rename,unlink,unlinkat,renameat -F auid>=$UID_MIN -F auid!=unset -F key=delete
EOF

cat > /etc/audit/rules.d/50-MAC-policy.rules <<EOF
-w /etc/apparmor/ -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy
EOF

cat > /etc/audit/rules.d/50-perm_chng.rules <<EOF
-a always,exit -F path=/usr/bin/chcon -F perm=x -F auid>=$UID_MIN -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/setfacl -F perm=x -F auid>=$UID_MIN -F auid!=unset -k perm_chng
-a always,exit -F path=/usr/bin/chacl -F perm=x -F auid>=$UID_MIN -F auid!=unset -k perm_chng
EOF

cat > /etc/audit/rules.d/50-usermod.rules <<EOF
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=$UID_MIN -F auid!=unset -k usermod
EOF

cat > /etc/audit/rules.d/50-kernel_modules.rules <<EOF
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module,create_module,query_module -F auid>=$UID_MIN -F auid!=unset -k kernel_modules
-a always,exit -F path=/usr/bin/kmod -F perm=x -F auid>=$UID_MIN -F auid!=unset -k kernel_modules
EOF

cat > /etc/audit/rules.d/50-user_emulation.rules <<EOF
-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-a always,exit -F arch=b32 -C euid!=uid -F auid!=unset -S execve -k user_emulation
EOF

cat > /etc/audit/rules.d/50-sudo.rules <<EOF
-w /var/log/sudo.log -p wa -k sudo_log_file
EOF

# Final immutable mode (CIS 6.2.3.20) — must be LAST .rules file (99-)
cat > /etc/audit/rules.d/99-finalize.rules <<'EOF'
-e 2
EOF

# Permissions on audit configs and tools (CIS 6.2.4.5, 6.2.4.8)
find /etc/audit/ -type f \( -name '*.conf' -o -name '*.rules' \) -exec chmod u-x,g-wx,o-rwx {} +
chmod go-w /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/auditd /sbin/augenrules 2>/dev/null || true

# Load rules
augenrules --load 2>&1 | tail -3 || true
yellow "    audit immutable mode set; rule changes from now on require reboot"

# ─── 11. Logging hardening ────────────────────────────────────────────
green "==> [11/13] journald rotation + rsyslog perms + /var/log perms"

# Journald rotation (CIS 6.1.1.3)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/60-cis-rotation.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemKeepFree=500M
RuntimeMaxUse=200M
RuntimeKeepFree=50M
MaxFileSec=1month
EOF
systemctl restart systemd-journald 2>/dev/null || true

# rsyslog file create mode (CIS 6.1.3.4)
if [ -d /etc/rsyslog.d ]; then
  cat > /etc/rsyslog.d/60-cis-mode.conf <<'EOF'
$FileCreateMode 0640
EOF
  systemctl reload rsyslog 2>/dev/null || true
fi

# /var/log file permissions (CIS 6.1.4.1) — sweep for over-permissive files
find /var/log -type f \( -perm /0137 -o ! -user root -o ! -group root \) 2>/dev/null | while read -r f; do
  base="$(basename "$f")"
  case "$base" in
    lastlog*|wtmp*|btmp*|README)
      chmod ug-x,o-wx "$f" 2>/dev/null || true
      ;;
    *.journal|*.journal~)
      chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true
      ;;
    secure|auth.log|syslog|messages|*.log)
      chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true
      ;;
    *)
      chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true
      ;;
  esac
done

# ─── 12. AIDE ─────────────────────────────────────────────────────────
green "==> [12/13] AIDE filesystem integrity (install + initialize)"
DEBIAN_FRONTEND=noninteractive apt-get install -y aide aide-common 2>&1 | tail -2

# Initialize DB if not already done (first-run only — takes ~5min)
if [ ! -f /var/lib/aide/aide.db ]; then
  yellow "    initializing AIDE database (this can take several minutes)..."
  aideinit -y -f >/dev/null 2>&1 || true
  [ -f /var/lib/aide/aide.db.new ] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
fi

# Enable daily check timer
systemctl unmask dailyaidecheck.timer dailyaidecheck.service 2>/dev/null || true
systemctl enable --now dailyaidecheck.timer 2>/dev/null || true

# ─── 13. /etc/security/opasswd permissions ────────────────────────────
green "==> [13/13] /etc/security/opasswd permissions (created on first password change)"
for f in /etc/security/opasswd /etc/security/opasswd.old; do
  if [ -e "$f" ]; then
    chmod u-x,go-rwx "$f"
    chown root:root "$f"
  fi
done

cat <<EOF

✓ CIS hardening complete.

Re-run Wazuh SCA to see updated findings:
  kubectl exec -n wazuh-agent <agent-pod> -- /var/ossec/bin/agent_control -R

Check this host's SCA status via the Wazuh dashboard. Expected: ~75 findings
resolved, ~10 remaining (architectural — see docs/06-reference/wazuh-sca-baseline.md).

GRUB was updated. Most settings active immediately; audit immutable mode and
new bootloader params take effect on next reboot.

EOF
