#!/usr/bin/env bash
# Component 11b — fail2ban for the bare-metal host.
# Installs the package (apt) and drops SecForge's hardened sshd jail
# config in place. Idempotent: re-running just refreshes the jail file.
#
# Config rationale (see /etc/fail2ban/jail.d/secforge.local):
#   - bantime 1h, escalating to 7d on repeat offenders.
#   - Tailnet (100.64.0.0/10) whitelisted so operator SSH never trips
#     the jail. The prior config had bantime=60s/maxretry=20 ("relax"
#     mode) so the operator's DHCP IP wouldn't lock them out, but
#     Tailscale (see project_teleport_stopped_tailscale.md) now gives
#     a stable identity.
#   - banaction=nftables matches the host's actual firewall backend.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
JAIL_SRC="$PLATFORM_DIR/manifests/fail2ban/secforge.local"
JAIL_DST=/etc/fail2ban/jail.d/secforge.local
RELAX_DST=/etc/fail2ban/jail.d/secforge-relax.local

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    echo "Try: sudo bash $0" >&2
    exit 1
fi

if [[ ! -f "$JAIL_SRC" ]]; then
    echo "ERROR: source jail config missing at $JAIL_SRC" >&2
    exit 1
fi

if ! dpkg -s fail2ban >/dev/null 2>&1; then
    echo ">>> Installing fail2ban"
    apt-get update -qq
    apt-get install -y fail2ban
else
    echo ">>> fail2ban already installed"
fi

if [[ -f "$RELAX_DST" ]]; then
    echo ">>> Removing legacy secforge-relax.local (now superseded by secforge.local)"
    mv "$RELAX_DST" "${RELAX_DST}.bak.$(date +%s)"
fi

echo ">>> Installing $JAIL_DST"
install -o root -g root -m 0644 "$JAIL_SRC" "$JAIL_DST"

echo ">>> Enabling + reloading fail2ban"
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban
sleep 2

echo ">>> Effective sshd jail settings:"
echo "    bantime:  $(fail2ban-client get sshd bantime)s"
echo "    findtime: $(fail2ban-client get sshd findtime)s"
echo "    maxretry: $(fail2ban-client get sshd maxretry)"
echo "    ignoreip:"
fail2ban-client get sshd ignoreip | sed 's/^/      /'

cat <<EOF

✓ Component 11b — fail2ban active with hardened sshd jail.

  Banlist:  sudo fail2ban-client status sshd
  Logs:     /var/log/fail2ban.log

EOF
