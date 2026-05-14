#!/usr/bin/env bash
# 11b — fail2ban for the bare-metal host.
#
# Installs fail2ban, drops jail.local (sshd jail + recidive escalation),
# enables and starts the systemd unit. The native wazuh-agent's
# <localfile> for /var/log/fail2ban.log (already in the rendered
# ossec.conf from component 10) feeds Wazuh both the failed-attempt
# cascade AND the resulting bans.
#
# Why this is here: native auditd captures every failed SSH attempt as a
# log event, but doesn't ACT on them. fail2ban closes the loop —
# detect-the-burst → ban-the-source-IP at the iptables layer for an hour
# (configurable; recidive jail extends to a week for repeat offenders).
#
# NOTE: jail.local's `ignoreip` already covers Tailscale CGNAT
# (100.64.0.0/10) — assumes component 10 (Tailscale) is your access path.
# If sshd is bound to the tailscale interface only (10b-sshd-lockdown.sh),
# fail2ban becomes a backstop rather than a primary defence.
# Recovery is at the bottom of this script's closing-message block.
#
# Pre-conditions:
#   - 11-wazuh-host-agent.sh ran (the agent's <localfile> for fail2ban.log
#     is already present in ossec.conf — if you ran 11 before this, the
#     localfile block exists but points at a file that won't exist until
#     fail2ban starts; that's fine, the agent retries gracefully)
#   - Run as root on the bare-metal host

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests/wazuh-host-agent"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (apt + iptables + systemctl)" >&2
        exit 1
    fi
}

install_fail2ban() {
    if dpkg -s fail2ban >/dev/null 2>&1; then
        echo ">>> fail2ban already installed"
        return
    fi
    echo ">>> Installing fail2ban"
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
}

drop_jail_local() {
    local src="$M/jail.local"
    local dst=/etc/fail2ban/jail.local

    [[ -f "$src" ]] || { echo "ERROR: jail.local source missing: $src" >&2; exit 1; }

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        echo ">>> /etc/fail2ban/jail.local already current"
    else
        # Back up any existing operator-modified file once.
        if [[ -f "$dst" ]] && [[ ! -f "$dst.preinstall.bak" ]]; then
            cp "$dst" "$dst.preinstall.bak"
            echo ">>> Backed up existing jail.local to $dst.preinstall.bak"
        fi
        echo ">>> Installing jail.local to $dst"
        install -m 0644 -o root -g root "$src" "$dst"
    fi

    # Confirm Tailscale CGNAT is in the ignoreip list.
    if ! grep -E "^ignoreip\s*=" "$dst" | grep -q "100.64.0.0/10"; then
        echo ""
        echo "  ⚠️  WARNING: jail.local 'ignoreip' does NOT include Tailscale CGNAT."
        echo "      If you SSH via Tailscale, you risk banning yourself."
        echo ""
        echo "      Add 100.64.0.0/10 to ignoreip:"
        echo "        sudo sed -i 's|^ignoreip = |& 100.64.0.0/10 |' $dst"
        echo "        sudo systemctl reload fail2ban"
        echo ""
    fi
}

enable_unit() {
    echo ">>> Enabling + starting fail2ban.service"
    systemctl daemon-reload
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 2
    systemctl --no-pager --lines=5 status fail2ban || true
}

verify_jails() {
    echo ">>> Active jails:"
    fail2ban-client status 2>/dev/null || true
    echo ""
    echo ">>> sshd jail detail:"
    fail2ban-client status sshd 2>/dev/null || echo "  (sshd jail not yet active — check 'systemctl status fail2ban' for errors)"
}

main() {
    require_root
    install_fail2ban
    drop_jail_local
    enable_unit
    verify_jails

    cat <<EOF

✓ Component 11b — fail2ban installed and configured.

  Config:        /etc/fail2ban/jail.local
  Log:           /var/log/fail2ban.log  (Wazuh agent tails this)
  Active jails:  sudo fail2ban-client status
  Banned IPs:    sudo fail2ban-client status sshd

Recovery (if you ban your own IP during testing):

  Option A — from the host's console (Hetzner web console gives you this):
    fail2ban-client set sshd unbanip <your.ip>
    iptables -L f2b-sshd -n --line-numbers
    iptables -D f2b-sshd <line-number>

  Option B — from the host directly (if you have an unbanned source):
    Same commands via SSH.

  Option C — Hetzner Cloud Firewall override:
    Add an explicit ALLOW rule for your source IP at the cloud-firewall
    layer; that runs BEFORE the host's iptables. Once you regain access,
    do the f2b-sshd cleanup above.

Verification (run the full attack-simulation suite now that 11 + 11a + 11b
are all in place):

  sudo bash $M/verify-detection.sh

Component 11 family complete.

What you've gained over the DaemonSet baseline:
  - Network interfaces, processes, packages, hotfixes — all visible
  - Rootcheck full profile (was disabled in DaemonSet path)
  - SCA (CIS Ubuntu) — was missing entirely
  - Process execution + identity changes + module loads via auditd — new
  - SSH brute force auto-banned, recidive jail catches repeat offenders
  - fail2ban events flow into Wazuh (closes the loop from detect → respond)

What's still NOT detected (deliberate scope; see manifests/wazuh-host-agent/README.md):
  - In-memory payloads, living-off-the-land binaries (Wazuh fundamentally
    can't see these without EDR-class telemetry like falco)
  - Network anomalies / C2 callbacks (needs a NIDS layer like Suricata)
  - App-layer attacks against your apps (needs WAF + app security events)
  - Outbound-only attacker traffic (needs egress monitoring)

These are tracked as future component 11c+ items in the README; pursue them
when threat model justifies the effort, not before.

EOF
}

main "$@"
