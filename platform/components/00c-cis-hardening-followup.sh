#!/usr/bin/env bash
# 00c — CIS hardening followup. Closes gaps left by 00b after first SCA scan
# revealed 68 still-failing checks. Of those, 33 were script bugs / missing
# items addressed here, 2 are reboot-pending (GRUB params), and ~33 are
# architectural exceptions documented in docs/06-reference/wazuh-sca-baseline.md.
#
# Run AFTER 00b-cis-hardening.sh. Idempotent.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. apport: unmask + purge (35545) ────────────────────────────────
# `systemctl mask` returns LoadState=masked, but the SCA check requires
# `disabled` or `not-found`. Purging the package alone leaves a stale
# masked symlink in /etc/systemd/system/, so unmask first.
green "==> [1/14] unmask + purge apport"
systemctl unmask apport.service 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    apport apport-symptoms python3-apport 2>&1 | tail -2 || true

# ─── 2. timesyncd NTP in MAIN file (35588) ────────────────────────────
# 00b put the NTP servers in a drop-in (correct per systemd best-practice),
# but the SCA rule explicitly inspects /etc/systemd/timesyncd.conf only.
green "==> [2/14] NTP in /etc/systemd/timesyncd.conf"
if ! grep -qE '^NTP=' /etc/systemd/timesyncd.conf 2>/dev/null; then
  printf '\n# CIS 2.3.2.1 (added by 00c-cis-hardening-followup.sh)\nNTP=ntp1.hetzner.de ntp2.hetzner.com ntp3.hetzner.net\nFallbackNTP=time.cloudflare.com pool.ntp.org\n' >> /etc/systemd/timesyncd.conf
fi
systemctl restart systemd-timesyncd 2>/dev/null || true

# ─── 3. /etc/cron.allow root:root mode 0640 (35600) ───────────────────
# CIS guide says to use root:crontab if the crontab group exists, but the
# Wazuh SCA rule requires exactly root:root. Pick the one the scanner wants.
green "==> [3/14] /etc/cron.allow root:root mode 0640"
[ -f /etc/cron.allow ] || touch /etc/cron.allow
chmod 0640 /etc/cron.allow
chown root:root /etc/cron.allow

# ─── 4. PermitRootLogin in MAIN sshd_config (35659) ───────────────────
# 00b put this in /etc/ssh/sshd_config.d/01-cis-access.conf (which DOES
# take effect because of the Include directive at the top of the main
# file), but the SCA rule explicitly looks at the main file. Add it there
# too. Both lines say `no` so behavior is consistent.
green "==> [4/14] PermitRootLogin no in /etc/ssh/sshd_config"
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%s)"
if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin no|' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
fi
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  green "    sshd reloaded"
else
  red "    sshd -t FAILED, restoring backup"
  mv /etc/ssh/sshd_config.bak-* /etc/ssh/sshd_config 2>/dev/null
  exit 1
fi

# ─── 5. sudo log file: drop-in + main file (35664) ────────────────────
# Wazuh SCA's directory pattern `d:/etc/sudoers.d -> \.*` literally means
# "files matching regex `\.*` (starts with dot)" — sudo files don't start
# with dot, so the rule never matches anything in sudoers.d. Write to BOTH
# the drop-in (the real fix) AND /etc/sudoers main file (to satisfy SCA).
green "==> [5/14] /etc/sudoers.d/00-cis-logfile + main /etc/sudoers"
printf 'Defaults\tlogfile=/var/log/sudo.log\n' > /etc/sudoers.d/00-cis-logfile
chmod 0440 /etc/sudoers.d/00-cis-logfile
chown root:root /etc/sudoers.d/00-cis-logfile
visudo -cf /etc/sudoers.d/00-cis-logfile

if ! grep -q '^Defaults.*logfile=' /etc/sudoers; then
  echo 'Defaults	logfile=/var/log/sudo.log' | EDITOR='tee -a' visudo
fi

# ─── 6. pwquality complexity additions (35681, 35682, 35683) ──────────
# 00b set minlen + credit values but missed minclass, maxrepeat, maxsequence.
green "==> [6/14] pwquality.conf with minclass, maxrepeat, maxsequence"
cat > /etc/security/pwquality.conf <<'EOF'
# CIS 5.3.3.2.* — Password complexity policy
minlen = 14
minclass = 4
maxrepeat = 3
maxsequence = 3
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
difok = 5
EOF
chmod 0644 /etc/security/pwquality.conf

# ─── 7. chage existing users (35695, 35696, 35698) ────────────────────
# 00b set login.defs defaults but the chage loop only fires for users with
# hashed passwords (`$...$` format in shadow). Re-run explicitly. Note:
# if NO user has a hashed password, these checks remain failed by design
# of the SCA rule — see baseline doc.
green "==> [7/14] chage on users with hashed passwords"
USERS_WITH_HASH=$(awk -F: '($2~/^\$.+\$/) {print $1}' /etc/shadow)
if [ -z "$USERS_WITH_HASH" ]; then
  yellow "    NO users have hashed passwords on this system."
  yellow "    35695/35696/35698 remain failed: login.defs IS correct, but"
  yellow "    the SCA shadow regex requires at least one \$hashed\$ entry."
else
  for u in $USERS_WITH_HASH; do
    if chage --maxdays 365 --mindays 1 --warndays 7 --inactive 45 "$u" 2>/dev/null; then
      yellow "    chage: $u"
    fi
  done
fi

# ─── 8. journald rotation in MAIN file (35708) ────────────────────────
# Same drop-in vs main-file issue as #2 / #4. SCA inspects the main file.
green "==> [8/14] journald rotation settings in /etc/systemd/journald.conf"
for kv in 'SystemMaxUse=1G' 'SystemKeepFree=500M' 'RuntimeMaxUse=200M' \
          'RuntimeKeepFree=50M' 'MaxFileSec=1month'; do
  k="${kv%%=*}"
  if grep -qE "^#?${k}=" /etc/systemd/journald.conf; then
    sed -i "s|^#\?${k}=.*|${kv}|" /etc/systemd/journald.conf
  else
    echo "$kv" >> /etc/systemd/journald.conf
  fi
done
systemctl restart systemd-journald

# ─── 9. /var/log permissions full sweep (35722) ───────────────────────
# 00b's sweep was too narrow. Re-do covering all the file-class buckets
# from the CIS-recommended remediation script.
green "==> [9/14] /var/log permissions full sweep"
find -L /var/log -type f \( -perm /0137 -o ! -user root -o ! -group root \) \
  -print0 2>/dev/null | while IFS= read -r -d $'\0' f; do
    base="$(basename "$f")"
    case "$base" in
      lastlog*|wtmp*|btmp*|README) chmod ug-x,o-wx "$f" 2>/dev/null || true;;
      *.journal|*.journal~)        chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true;;
      secure|auth.log|syslog|messages|*.log)
                                   chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true;;
      *)                           chmod u-x,g-wx,o-rwx "$f" 2>/dev/null || true;;
    esac
done

# ─── 10. Missing audit rules: scope + logins (35731, 35741) ───────────
# Adding new rule files with `-e 2` (immutable) already loaded means they
# load on next boot; auditctl --reload won't pick them up.
green "==> [10/14] /etc/audit/rules.d/{50-scope,50-login}.rules"
cat > /etc/audit/rules.d/50-scope.rules <<'EOF'
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
EOF
cat > /etc/audit/rules.d/50-login.rules <<'EOF'
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
EOF
chmod u-x,g-wx,o-rwx /etc/audit/rules.d/50-scope.rules /etc/audit/rules.d/50-login.rules
yellow "    new audit rules will activate at next reboot (immutable mode active)"

# ─── 11. AIDE audit-tool integrity (35760) ────────────────────────────
green "==> [11/14] audit tool integrity in /etc/aide/aide.conf"
if ! grep -q 'auditctl.*sha512' /etc/aide/aide.conf; then
  cat >> /etc/aide/aide.conf <<'EOF'

# CIS 6.3.3 — Audit tool integrity (added by 00c-cis-hardening-followup.sh)
/sbin/auditctl p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/auditd p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/ausearch p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/aureport p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/autrace p+i+n+u+g+s+b+acl+xattrs+sha512
/sbin/augenrules p+i+n+u+g+s+b+acl+xattrs+sha512
EOF
  yellow "    aide.db will be re-init'd on next 'aideinit -y -f' run"
fi

# ─── 12. Re-render PAM stack (35689 verify) ───────────────────────────
# `pam-auth-update --enable` is a no-op on already-enabled profiles (no
# re-render). `--package` re-renders all common-* files from the current
# profile set, which picks up the use_authtok edit on /usr/share/pam-configs/unix.
green "==> [12/14] pam-auth-update --package (re-render common-*)"
DEBIAN_FRONTEND=noninteractive pam-auth-update --package 2>&1 | tail -3 || true

# ─── 13. UFW loopback rules (35623) ───────────────────────────────────
# 00b doesn't set these; required for the SCA loopback rule to pass.
green "==> [13/14] UFW loopback ALLOW + spoofing DENY rules"
ufw allow in on lo 2>&1 | tail -1
ufw allow out on lo 2>&1 | tail -1
ufw deny in from 127.0.0.0/8 2>&1 | tail -1
ufw deny in from ::1 2>&1 | tail -1

# ─── 14. Sysctl runtime apply (35616) ─────────────────────────────────
# 00b's sysctl --system doesn't always override per-interface settings
# k3s creates before the script runs. Force runtime values to match config.
green "==> [14/14] sysctl runtime apply (log_martians, secure_redirects)"
sysctl -w net.ipv4.conf.all.log_martians=1 >/dev/null
sysctl -w net.ipv4.conf.default.log_martians=1 >/dev/null
sysctl -w net.ipv4.conf.all.secure_redirects=0 >/dev/null
sysctl -w net.ipv4.conf.default.secure_redirects=0 >/dev/null

cat <<EOF

✓ Followup hardening complete.

Activates on REBOOT:
  - /etc/audit/rules.d/50-scope.rules and 50-login.rules
    (held by audit immutable mode -e 2)
  - GRUB params: audit=1, audit_backlog_limit=8192
    (need new initramfs / kernel cmdline)
  - module_blacklist=ksmbd,nfsd,...
    (kernel-level enforcement, not just modprobe)

After reboot, re-trigger SCA scan. Expected: ~30 architectural findings,
all documented in docs/06-reference/wazuh-sca-baseline.md.
EOF
