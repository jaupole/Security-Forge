#!/usr/bin/env bash
# 10b — Bind sshd to the tailnet interface only (lock down public SSH).
#
# After this runs, the public internet has NO path to SSH:
#   1. sshd binds to 127.0.0.1 + the tailscale0 interface only — public
#      NIC is no longer a listener.
#   2. PasswordAuthentication is disabled (key-only).
#   3. Optional: Hetzner Cloud Firewall closes port 22 (commands printed
#      at the end; not auto-applied — operator runs them via hcloud CLI
#      or web console).
#
# CRITICAL safety guards (the script REFUSES to proceed if any fails):
#   - Tailscale daemon must be active and have an active tailnet session
#   - The tailscale0 interface must exist with a valid IPv4
#   - The current SSH session (if running over SSH) must be sourced from
#     a tailnet IP — proves the tailnet path works for SSH
#   - At least one authorized_keys file must exist for the user (so
#     PasswordAuthentication=no doesn't lock the operator out)
#
# Recovery if the operator gets locked out anyway:
#   - Hetzner web console (KVM) → boot rescue mode → mount filesystem →
#     edit /etc/ssh/sshd_config to remove the ListenAddress restriction →
#     reboot. Always-available backup path.
#
# Pre-conditions:
#   - 10-tailscale.sh ran AND your laptop is verified reachable
#   - 10a-ingress-tailnet-split.sh ran (admin UIs locked down too)
#   - Run as root on the bare-metal Hetzner host
#   - You are SSH'd into the host via the tailnet IP RIGHT NOW (recommended)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-secforge-tailnet.conf

# ── Sanity ────────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (edit sshd config + restart sshd)" >&2
        exit 1
    fi
}

require_tailscale_active() {
    if ! systemctl is-active --quiet tailscaled; then
        echo "ERROR: tailscaled is not active. Run 10-tailscale.sh first." >&2
        exit 1
    fi
    local state
    state=$(tailscale status --json 2>/dev/null | grep -oE '"BackendState":\s*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [[ "$state" != "Running" ]]; then
        echo "ERROR: Tailscale BackendState is '$state', not Running. Operator needs to log in via 10-tailscale.sh." >&2
        exit 1
    fi
}

require_tailnet_iface() {
    if ! ip link show tailscale0 >/dev/null 2>&1; then
        echo "ERROR: tailscale0 interface does not exist. Tailscale daemon may not have come up cleanly." >&2
        exit 1
    fi
    TAILNET_IP=$(ip -4 -o addr show tailscale0 | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [[ -z "$TAILNET_IP" ]]; then
        echo "ERROR: tailscale0 has no IPv4. Run: tailscale up" >&2
        exit 1
    fi
    echo ">>> Tailnet interface: tailscale0 = $TAILNET_IP"
}

require_authorized_keys() {
    # Find users with authorized_keys files. At least one must exist or
    # PasswordAuthentication=no will lock everyone out.
    local found=0
    for home in /root /home/*; do
        [[ -d "$home" ]] || continue
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            local user
            user=$(basename "$home")
            [[ "$user" == "*" ]] && user=root
            [[ "$home" == "/root" ]] && user=root
            echo ">>> Found authorized_keys for user: $user ($home/.ssh/authorized_keys)"
            found=$(( found + 1 ))
        fi
    done
    if (( found == 0 )); then
        echo "ERROR: NO authorized_keys file found anywhere under /root or /home/*." >&2
        echo "  Disabling PasswordAuthentication will lock everyone out." >&2
        echo "  Add a public key to (e.g.) /home/ops/.ssh/authorized_keys first." >&2
        exit 1
    fi
}

verify_session_is_via_tailnet() {
    # Best-effort check: if we're running over SSH, is the SSH connection
    # coming from a tailnet IP? If yes — great, the tailnet path is proven.
    # If no — warn but allow override.
    if [[ -z "${SSH_CONNECTION:-}" ]]; then
        echo ">>> Not running over SSH (likely local console) — skipping session-path check"
        return
    fi

    local src_ip
    src_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    if [[ "$src_ip" == 100.* ]]; then
        echo ">>> Current SSH session is from tailnet IP $src_ip — tailnet SSH path proven"
        return
    fi

    echo ""
    echo "  ⚠️  WARNING: this SSH session is from $src_ip — NOT a tailnet IP (100.x.x.x)."
    echo ""
    echo "      You're about to bind sshd to the tailnet interface only. After this"
    echo "      runs, your CURRENT session may stay alive (existing TCP connections"
    echo "      survive sshd config reload), but new public SSH connections will fail."
    echo ""
    echo "      RECOMMENDED: open a second SSH session via the tailnet IP first:"
    echo "        ssh ops@$TAILNET_IP"
    echo "      then re-run this script from THAT session."
    echo ""
    if [[ "${FORCE_LOCKDOWN:-no}" != "yes" ]]; then
        echo "      To proceed anyway: FORCE_LOCKDOWN=yes bash $0"
        exit 1
    fi
    echo "      FORCE_LOCKDOWN=yes set — proceeding."
}

# ── Apply the lockdown ────────────────────────────────────────────────────

apply_sshd_dropin() {
    # Use a drop-in under /etc/ssh/sshd_config.d/ rather than editing
    # sshd_config directly — survives package upgrades, easy to revert
    # by deleting the file.
    echo ">>> Writing sshd drop-in: $SSHD_DROPIN"
    cat > "$SSHD_DROPIN" <<EOF
# SecForge component 10b — bind sshd to loopback + tailnet only.
# Generated by 10b-sshd-lockdown.sh; revert by removing this file +
# restarting sshd.

# Loopback (for emergency local console + Hetzner rescue mode).
ListenAddress 127.0.0.1
ListenAddress ::1

# Tailnet interface (operator access).
ListenAddress $TAILNET_IP

# Auth hardening — keys only, no passwords.
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

# Refuse root password login (root via key still allowed; tighten later).
PermitRootLogin prohibit-password
EOF
    chmod 0644 "$SSHD_DROPIN"
}

validate_and_reload_sshd() {
    echo ">>> Validating sshd config syntax (sshd -t)"
    if ! sshd -t; then
        echo "ERROR: sshd -t failed. Drop-in is invalid; removing it." >&2
        rm -f "$SSHD_DROPIN"
        exit 1
    fi

    echo ">>> Reloading sshd (existing sessions stay alive)"
    systemctl reload sshd
    sleep 1

    # Confirm sshd is bound to the new interfaces only.
    echo ">>> sshd listening sockets after reload:"
    ss -tlnp | grep sshd || echo "    (no sshd sockets — something went wrong, check 'journalctl -u sshd')"
}

# ── Hetzner Cloud Firewall guidance (manual; not auto-applied) ────────────

print_hetzner_fw_guidance() {
    cat <<'EOF'

============================================================
 Manual step — Hetzner Cloud Firewall
============================================================

sshd is now bound to the tailnet interface + loopback only. Public-internet
TCP packets to port 22 will hit a closed port (no listener) — but they'll
still consume bandwidth + show up in your firewall logs as connection
attempts. Cleanest fix: drop them at the cloud firewall.

If using `hcloud` CLI (recommended; cleanest revert path):

  # List firewalls to find yours
  hcloud firewall list

  # Replace <FW_ID> with your firewall ID; deletes the inbound SSH rule
  hcloud firewall delete-rule <FW_ID> \
      --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0

If using the web console:

  https://console.hetzner.cloud/projects/<id>/firewalls
    → click your firewall
    → Inbound rules
    → delete any rule allowing TCP 22 from 0.0.0.0/0
    → leave the UDP 41641 rule (Tailscale's WireGuard direct path)

To revert (if you need public sshd back):

  hcloud firewall add-rule <FW_ID> \
      --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0
  AND remove $SSHD_DROPIN, then `systemctl reload sshd`.

EOF
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
    require_root
    require_tailscale_active
    require_tailnet_iface
    require_authorized_keys
    verify_session_is_via_tailnet

    apply_sshd_dropin
    validate_and_reload_sshd
    print_hetzner_fw_guidance

    cat <<EOF

✓ Component 10b — sshd locked down to tailnet + loopback.

  Drop-in:        $SSHD_DROPIN
  sshd binds to:  127.0.0.1, ::1, $TAILNET_IP
  Auth:           keys only (PasswordAuthentication=no)

VERIFY before closing this terminal:

  1. Open a NEW SSH session via the tailnet:
       ssh ops@$TAILNET_IP
     If this fails, do NOT close your current session. Investigate.

  2. From off-tailnet (mobile data with Tailscale OFF), confirm public
     SSH is unreachable:
       ssh -o ConnectTimeout=5 ops@<public-ip>     # should hang or refuse

  3. Apply the Hetzner Cloud Firewall changes printed above.

To revert:
  sudo rm $SSHD_DROPIN
  sudo systemctl reload sshd

Component 10 family (Tailscale + ingress split + sshd lockdown) complete.

Next:
  bash $SCRIPT_DIR/11-wazuh-host-agent.sh    (now safe — tailnet access proven)
  bash $SCRIPT_DIR/11a-auditd.sh
  bash $SCRIPT_DIR/11b-fail2ban.sh

EOF
}

main "$@"
