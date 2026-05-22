#!/usr/bin/env bash
# 10 — Tailscale operator-access mesh.
#
# Installs the Tailscale daemon on the bare-metal host and brings it up.
# Provides a stable WireGuard mesh between the host and the operator's
# devices regardless of any device's public IP — solves the DHCP-rotation
# problem and replaces the access-control role Teleport was originally
# going to fill.
#
# This script is SAFE — it only ADDS access (the tailnet path), it does
# not REMOVE existing access. After running:
#   1. The host has a tailnet IP (100.x.x.x) reachable from your laptop
#      once the laptop also joins the same tailnet.
#   2. Public sshd on port 22 still works exactly as before.
#   3. Admin Ingresses (Wazuh, Grafana, etc.) are still public.
# Components 10a and 10b are what then RESTRICT public access. Run them
# only after verifying tailnet reachability from your laptop.
#
# See platform/manifests/tailscale/README.md for full design rationale,
# operational notes, and recovery scenarios.
#
# Pre-conditions:
#   - Run as root on the bare-metal Hetzner host
#   - Outbound HTTPS to controlplane.tailscale.com works (or pre-auth key
#     is supplied via TAILSCALE_AUTHKEY env var to skip browser auth)
#
# Auth modes:
#   - INTERACTIVE (default): script runs `tailscale up` with --ssh disabled
#     and prints the auth URL. Operator opens the URL in a browser, signs in
#     with their Tailscale account, host joins the tailnet.
#   - PRE-AUTH KEY: set TAILSCALE_AUTHKEY=tskey-auth-... before invoking.
#     The host joins automatically without browser interaction. Generate
#     keys at https://login.tailscale.com/admin/settings/keys
#       Recommended for the host: reusable=NO, ephemeral=NO, expiry=90d
#       (the resulting key is single-use; subsequent re-runs of this
#       script will skip the join because the host is already up.)
#
# Idempotent: re-running detects an existing Tailscale install + active
# session and skips the join. To force a re-join: `sudo tailscale logout`
# then re-run with TAILSCALE_AUTHKEY set.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

# Hostname used for the tailnet machine name. Defaults to the system's
# hostname; override via TAILSCALE_HOSTNAME if needed.
TS_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"

# ── Sanity checks ─────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (apt + systemctl + WireGuard kernel module)" >&2
        echo "Try: sudo bash $0" >&2
        exit 1
    fi
}

require_host_tools() {
    for cmd in apt-get systemctl curl gpg; do
        if ! command -v "$cmd" >/dev/null; then
            echo "ERROR: required command not found: $cmd" >&2
            exit 1
        fi
    done
}

# ── Tailscale apt repo + install ──────────────────────────────────────────

ensure_apt_repo() {
    local key_path=/usr/share/keyrings/tailscale-archive-keyring.gpg
    local list_path=/etc/apt/sources.list.d/tailscale.list

    # Tailscale publishes per-distro per-codename keyrings + lists at
    # https://pkgs.tailscale.com/. We use the noble repo for Ubuntu 24.04.
    local distro_codename=noble
    local key_url="https://pkgs.tailscale.com/stable/ubuntu/${distro_codename}.noarmor.gpg"
    local list_url="https://pkgs.tailscale.com/stable/ubuntu/${distro_codename}.tailscale-keyring.list"

    if [[ ! -f "$key_path" ]]; then
        echo ">>> Adding Tailscale GPG key to $key_path"
        curl -fsSL "$key_url" -o "$key_path"
        chmod 644 "$key_path"
    fi

    if [[ ! -f "$list_path" ]]; then
        echo ">>> Adding Tailscale apt source to $list_path"
        curl -fsSL "$list_url" -o "$list_path"
        chmod 644 "$list_path"
    fi

    echo ">>> apt-get update"
    apt-get update -qq
}

install_tailscale_pkg() {
    if dpkg -s tailscale >/dev/null 2>&1; then
        local installed
        installed=$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null || true)
        echo ">>> tailscale already installed (version $installed)"
        return
    fi
    echo ">>> Installing tailscale"
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
}

enable_unit() {
    if systemctl is-enabled tailscaled >/dev/null 2>&1; then
        echo ">>> tailscaled already enabled"
    else
        echo ">>> Enabling tailscaled"
        systemctl enable tailscaled
    fi
    if ! systemctl is-active --quiet tailscaled; then
        echo ">>> Starting tailscaled"
        systemctl start tailscaled
        sleep 2
    fi
}

# ── Bring up the tailnet session ──────────────────────────────────────────

is_tailscale_up() {
    # `tailscale status --json` exits non-zero if not logged in.
    # `BackendState` of "Running" means the daemon has an active tailnet session.
    local state
    state=$(tailscale status --json 2>/dev/null | grep -oE '"BackendState":\s*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    [[ "$state" == "Running" ]]
}

bring_up_tailnet() {
    if is_tailscale_up; then
        local current_ip
        current_ip=$(tailscale ip -4 2>/dev/null | head -1)
        echo ">>> Tailscale already up — host has tailnet IP $current_ip"
        return
    fi

    local up_args=(
        --hostname="$TS_HOSTNAME"
        --accept-dns=false             # don't override host's DNS resolver
        --accept-routes=false          # don't pull routes from other peers
        --advertise-tags=tag:server    # for future ACLs; harmless if no ACLs
        --ssh=false                    # use native sshd, not Tailscale SSH
    )

    if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
        echo ">>> Bringing up tailnet via pre-auth key (non-interactive)"
        up_args+=(--auth-key="$TAILSCALE_AUTHKEY")
        tailscale up "${up_args[@]}"
    else
        echo ">>> Bringing up tailnet (interactive — open the auth URL below in a browser)"
        echo ""
        echo "    To skip browser auth on future runs, generate a pre-auth key at"
        echo "    https://login.tailscale.com/admin/settings/keys and re-run with"
        echo "    TAILSCALE_AUTHKEY=tskey-auth-... bash $0"
        echo ""
        # tailscale up prints the auth URL to stdout/stderr and waits for completion.
        tailscale up "${up_args[@]}"
    fi
}

# ── Verify ────────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo ">>> Tailscale status:"
    tailscale status 2>/dev/null || true
    echo ""
    echo ">>> Tailscale IPs for this host:"
    tailscale ip 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
    require_root
    require_host_tools
    ensure_apt_repo
    install_tailscale_pkg
    enable_unit
    bring_up_tailnet
    show_status

    local tailnet_ip
    tailnet_ip=$(tailscale ip -4 2>/dev/null | head -1)
    local magic_dns_name
    magic_dns_name=$(tailscale status --json 2>/dev/null | grep -oE '"MagicDNSSuffix":\s*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    cat <<EOF

✓ Component 10 — Tailscale installed and joined.

  Hostname:       $TS_HOSTNAME
  Tailnet IPv4:   $tailnet_ip
  Tailnet name:   ${TS_HOSTNAME}.${magic_dns_name:-<your-tailnet>.ts.net}

NEXT STEPS — verify before running 10a + 10b:

  1. On YOUR LAPTOP, install Tailscale and join the same tailnet:
       https://tailscale.com/download
     Sign in with the same Tailscale account you used here.

  2. From your laptop, confirm reachability:
       ping $tailnet_ip
       ssh ops@$tailnet_ip       # or via MagicDNS: ssh ops@${TS_HOSTNAME}
     Both should work. SSH still routes to the public sshd at this point —
     component 10b is what locks it down to tailnet-only.

  3. ONCE LAPTOP CAN REACH THE HOST VIA TAILNET, proceed:
       bash $SCRIPT_DIR/10a-ingress-tailnet-split.sh
       bash $SCRIPT_DIR/10b-sshd-lockdown.sh

  4. Then continue with the wazuh agent buildout:
       bash $SCRIPT_DIR/11-wazuh-host-agent.sh
       bash $SCRIPT_DIR/11a-auditd.sh
       bash $SCRIPT_DIR/11b-fail2ban.sh

If your laptop can't reach the host via the tailnet IP, DO NOT run 10b —
it will lock you out of public sshd. Debug via:
  - Both ends: tailscale status
  - Tailscale admin: https://login.tailscale.com/admin/machines
  - Hetzner Cloud Firewall: confirm UDP 41641 outbound is not blocked

EOF
}

main "$@"
