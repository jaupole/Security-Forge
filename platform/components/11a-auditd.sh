#!/usr/bin/env bash
# 11a — Linux audit subsystem (auditd) for the bare-metal host.
#
# Installs auditd + audispd-plugins, drops the curated ruleset at
# /etc/audit/rules.d/secforge.rules, loads the rules, restarts auditd.
#
# The native wazuh-agent's <localfile> block for /var/log/audit/audit.log
# (already present in the rendered ossec.conf from component 10) starts
# producing alerts on the next read cycle — no agent restart needed.
#
# What this gives Wazuh:
#   - process execution (execve syscalls, the single biggest detection
#     upgrade for "what is running on my host right now")
#   - file writes to identity files (passwd, shadow, sudoers)
#   - SSH config + authorized_keys changes
#   - kernel module load/unload
#   - cron / systemd unit changes (persistence detection)
#   - clock manipulation, mount events, container runtime config changes
#   - audit subsystem tampering (watch-the-watcher)
#
# Tuning note: auditd is loud. 50-200 events/sec on an idle box, more under
# workload. The Wazuh manager handles this fine, but the dashboard's "all
# events" view becomes noisy. Configure the operational dashboard view to
# filter rule.level >= 5 — raw events are still queryable when you need them.
#
# Pre-conditions:
#   - 11-wazuh-host-agent.sh ran (native agent installed and reporting)
#   - Run as root on the bare-metal host

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests/wazuh-host-agent"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (apt + augenrules + systemctl)" >&2
        exit 1
    fi
}

install_auditd() {
    if dpkg -s auditd >/dev/null 2>&1 && dpkg -s audispd-plugins >/dev/null 2>&1; then
        echo ">>> auditd + audispd-plugins already installed"
        return
    fi
    echo ">>> Installing auditd + audispd-plugins"
    DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins
}

drop_ruleset() {
    local src="$M/secforge.audit.rules"
    local dst=/etc/audit/rules.d/secforge.rules

    [[ -f "$src" ]] || { echo "ERROR: ruleset source missing: $src" >&2; exit 1; }

    # Diff-and-update: only rewrite if content changed (auditd reload is
    # cheap but skipping it on no-op runs keeps the operation log cleaner).
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        echo ">>> Ruleset at $dst already current"
    else
        echo ">>> Installing ruleset to $dst"
        install -m 0640 -o root -g root "$src" "$dst"
    fi

    # Disable Ubuntu's default audit.rules (which is empty / placeholder)
    # interfering with our ruleset's load order. augenrules concatenates
    # all files in /etc/audit/rules.d/ in lexical order; secforge.rules
    # sorts after audit.rules.* defaults, which is what we want.
}

load_rules() {
    echo ">>> Loading audit rules via augenrules"
    augenrules --load
    echo ">>> Restarting auditd"
    systemctl restart auditd
    sleep 2

    local loaded
    loaded=$(auditctl -l | wc -l)
    echo "    $loaded rules currently loaded"
    if (( loaded < 20 )); then
        echo "WARNING: fewer rules than expected. Inspect:" >&2
        echo "  auditctl -l" >&2
        echo "  augenrules --check" >&2
    fi
}

verify_agent_can_read() {
    if [[ ! -f /var/log/audit/audit.log ]]; then
        echo "WARNING: /var/log/audit/audit.log not yet created. auditd just started?" >&2
        return
    fi

    # The wazuh user must be in the `adm` group (or have read access to
    # /var/log/audit/) to ingest the file. On stock Ubuntu, the audit.log
    # is mode 0600 root:root and the wazuh user can't read it directly.
    # Two fixes — choose one:
    #   (a) Add wazuh to a group that can read /var/log/audit/ (adm)
    #   (b) Adjust auditd log_group= setting
    # Going with (b) — it's the upstream-recommended approach.
    if grep -qE '^log_group\s*=\s*adm' /etc/audit/auditd.conf; then
        echo ">>> auditd log_group already set to 'adm'"
    else
        echo ">>> Setting auditd log_group = adm in /etc/audit/auditd.conf"
        if grep -qE '^log_group\s*=' /etc/audit/auditd.conf; then
            sed -i 's|^log_group\s*=.*|log_group = adm|' /etc/audit/auditd.conf
        else
            echo "log_group = adm" >> /etc/audit/auditd.conf
        fi
        systemctl restart auditd
        sleep 1
    fi

    # Make wazuh a member of adm so it can read /var/log/audit/audit.log.
    if id wazuh 2>/dev/null | grep -q '\badm\b'; then
        echo ">>> wazuh user already in adm group"
    else
        echo ">>> Adding wazuh user to adm group (for audit.log read access)"
        usermod -a -G adm wazuh
        # Agent must restart to pick up the new group membership.
        systemctl restart wazuh-agent
        sleep 2
    fi
}

main() {
    require_root
    install_auditd
    drop_ruleset
    load_rules
    verify_agent_can_read

    cat <<EOF

✓ Component 11a — auditd installed and ruleset loaded.

  Ruleset:    /etc/audit/rules.d/secforge.rules
  Audit log:  /var/log/audit/audit.log
  Live rules: auditctl -l
  Search:     ausearch -k <keyname>   (e.g. -k identity, -k pkg_install)

Verification (after 11b also runs):
  sudo bash $M/verify-detection.sh

Quick sanity: trigger an audited action and confirm Wazuh sees it:
  sudo true                         # -k privileged_exec watch on /usr/bin/sudo
  cat /etc/shadow > /dev/null       # -k identity watch on /etc/shadow
  Then in the Wazuh dashboard's Security Events view, filter to "audit" —
  events should appear within seconds.

Next:
  bash $SCRIPT_DIR/11b-fail2ban.sh

EOF
}

main "$@"
