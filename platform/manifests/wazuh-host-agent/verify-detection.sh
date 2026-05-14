#!/usr/bin/env bash
# verify-detection.sh — attack-simulation suite for component 10.
#
# Fires known attacker behaviours and asserts the corresponding Wazuh alert
# appears in the manager's alerts log within a target latency.
#
# Run after 10b-fail2ban.sh completes:
#   sudo bash platform/manifests/wazuh-host-agent/verify-detection.sh
#
# Exits non-zero if any test fails. Each test prints PASS/FAIL with the alert
# rule.id it found (or the absence of an expected alert).
#
# IMPORTANT — must run as root on the same host where the agent is installed
# (uses sudo-equivalent actions and reads /var/ossec/logs/active-responses.log
# locally; queries the manager pod via kubectl for the alert log).
#
# Each simulation is reversible — packages installed are removed, files
# touched are deleted, sysctls changed are restored.

set -uo pipefail   # NOT -e: we want to keep going on test failures.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

NS_MGR=wazuh
MGR_POD=wazuh-manager-0
ALERTS_LOG=/var/ossec/logs/alerts/alerts.json

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (need to invoke sudo, write to /etc, etc.)" >&2
        exit 1
    fi
}

require_kubectl() {
    if ! command -v kubectl >/dev/null; then
        echo "ERROR: kubectl not on PATH. Need cluster access to read alerts.json from $MGR_POD." >&2
        exit 1
    fi
    if ! kubectl -n "$NS_MGR" get pod "$MGR_POD" >/dev/null 2>&1; then
        echo "ERROR: $NS_MGR/$MGR_POD not reachable. Is the cluster up?" >&2
        exit 1
    fi
}

# Capture the current end-of-file line count of alerts.json so each test
# only inspects events that fire AFTER its trigger.
mark_alerts_position() {
    kubectl exec -n "$NS_MGR" "$MGR_POD" -- wc -l "$ALERTS_LOG" 2>/dev/null \
        | awk '{print $1}'
}

# Tail alerts.json from `since_line` for up to `timeout_s`, looking for any
# event matching `pattern` (passed to grep -E). Returns 0 if found, 1 if not.
wait_for_alert() {
    local since_line="$1"
    local pattern="$2"
    local timeout_s="${3:-30}"

    local elapsed=0
    while (( elapsed < timeout_s )); do
        local current
        current=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- wc -l "$ALERTS_LOG" 2>/dev/null \
            | awk '{print $1}')
        if (( current > since_line )); then
            local new_lines=$(( current - since_line ))
            if kubectl exec -n "$NS_MGR" "$MGR_POD" -- \
                    tail -n "$new_lines" "$ALERTS_LOG" 2>/dev/null \
                    | grep -E "$pattern" >/dev/null; then
                return 0
            fi
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    return 1
}

run_test() {
    local name="$1"
    local trigger_fn="$2"
    local pattern="$3"
    local timeout_s="${4:-30}"
    local cleanup_fn="${5:-true}"

    echo
    echo -e "${YELLOW}── TEST: ${name}${NC}"
    local since
    since=$(mark_alerts_position)
    if [[ -z "$since" ]]; then
        echo -e "  ${RED}FAIL${NC} — could not read alerts.json position"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        RESULTS+=("FAIL: $name (alerts.json unreadable)")
        return
    fi

    echo "  triggering..."
    "$trigger_fn"

    echo "  waiting up to ${timeout_s}s for alert matching: $pattern"
    if wait_for_alert "$since" "$pattern" "$timeout_s"; then
        echo -e "  ${GREEN}PASS${NC}"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
        RESULTS+=("PASS: $name")
    else
        echo -e "  ${RED}FAIL${NC} — no matching alert within ${timeout_s}s"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        RESULTS+=("FAIL: $name (no alert)")
    fi

    "$cleanup_fn"
}

# ── Test 1: privileged FIM violation ──────────────────────────────────────
trigger_fim() {
    touch /etc/secforge-fim-test-$$
}
cleanup_fim() {
    rm -f /etc/secforge-fim-test-$$
}

# ── Test 2: privileged file read (audit watch on /etc/shadow) ─────────────
trigger_shadow_read() {
    cat /etc/shadow > /dev/null
}

# ── Test 3: suspicious process exec (audit watch on /usr/bin/sudo) ────────
trigger_sudo_exec() {
    sudo true
}

# ── Test 4: package install (apt history + dpkg watch) ────────────────────
trigger_pkg_install() {
    apt-get install -y --no-install-recommends figlet >/dev/null 2>&1
}
cleanup_pkg_install() {
    apt-get purge -y figlet >/dev/null 2>&1
}

# ── Test 5: kernel module enumeration attempt (audit syscall) ─────────────
trigger_module_attempt() {
    # `modprobe -n -v dummy` is a dry-run; doesn't actually load. The audit
    # watch on init_module syscall fires regardless because finit_module is
    # called during the dry-run. If your kernel doesn't have dummy module,
    # try a known-installed one with -n flag to keep it harmless.
    modprobe -n -v dummy >/dev/null 2>&1 || modprobe -n -v dummy0 >/dev/null 2>&1 || true
}

# ── Test 6: sshd brute-force simulation (auth.log → sshd jail) ────────────
trigger_ssh_bruteforce() {
    # Use a controlled invalid-user attempt. Local connection to sshd, 6 times
    # in quick succession, exceeding the maxretry=5 threshold. Source IP is
    # always 127.0.0.1 — which is in `ignoreip` so fail2ban will NOT actually
    # ban. We just want the failed-login alerts, not a self-inflicted ban.
    for i in {1..6}; do
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=2 \
            "secforge-test-noexist-user-$$@127.0.0.1" exit 2>/dev/null || true
    done
}

# ── Test 7: SCA drift (sysctl change) ─────────────────────────────────────
SCA_ORIG_RANDOMIZE_VA=""
trigger_sca_drift() {
    SCA_ORIG_RANDOMIZE_VA=$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo 2)
    sysctl -w kernel.randomize_va_space=0 >/dev/null
    echo "  (waiting for next SCA scan — note: SCA scans every 12h by default;"
    echo "   this test will FAIL unless you trigger an immediate scan via:"
    echo "   /var/ossec/bin/wazuh-control restart && wait)"
}
cleanup_sca_drift() {
    if [[ -n "$SCA_ORIG_RANDOMIZE_VA" ]]; then
        sysctl -w kernel.randomize_va_space="$SCA_ORIG_RANDOMIZE_VA" >/dev/null
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
    require_root
    require_kubectl

    cat <<'EOF'

============================================================
 SecForge — Wazuh detection verification suite
============================================================

Each test fires an attacker-shaped behaviour and waits up to 30s for the
matching Wazuh alert to land in the manager's alerts.json.

Reversible actions only — files touched are deleted, packages installed are
purged, sysctls modified are restored.

EOF

    # Rule patterns are matched against alerts.json lines.
    # `rule.id` field varies by Wazuh version; pattern matches the numeric
    # range or rule.description string for resilience.

    run_test "privileged FIM violation (touch under /etc)" \
        trigger_fim \
        '"rule":{"level":[5-9]|[1-9][0-9]+,.*"description":".*[Ii]ntegrity"' \
        60 \
        cleanup_fim

    run_test "privileged file read (cat /etc/shadow)" \
        trigger_shadow_read \
        '"rule":\{.*"id":"(80784|80789|80790|80791)"' \
        15 \
        true

    run_test "sudo invocation (audit execve on /usr/bin/sudo)" \
        trigger_sudo_exec \
        '"rule":\{.*"id":"(5402|80700|80785)"' \
        15 \
        true

    run_test "package install (apt install figlet)" \
        trigger_pkg_install \
        '"rule":\{.*"id":"(2902|2903|80784)"' \
        15 \
        cleanup_pkg_install

    run_test "kernel module attempt (modprobe dry-run)" \
        trigger_module_attempt \
        '"rule":\{.*"id":"(80790|80791)"' \
        15 \
        true

    run_test "sshd brute-force (6 invalid logins from 127.0.0.1)" \
        trigger_ssh_bruteforce \
        '"rule":\{.*"id":"(5710|5712|5716|5720)"' \
        20 \
        true

    # SCA test is opt-in — requires a manual scan trigger to be useful in CI.
    if [[ "${INCLUDE_SCA_TEST:-no}" == "yes" ]]; then
        run_test "SCA drift (kernel.randomize_va_space=0)" \
            trigger_sca_drift \
            '"rule":\{.*"id":"(19010|19011)"' \
            120 \
            cleanup_sca_drift
    else
        echo
        echo -e "${YELLOW}── SKIPPED: SCA drift test (set INCLUDE_SCA_TEST=yes to run; takes 2+ min)${NC}"
    fi

    # ── Summary ───────────────────────────────────────────────────────────
    echo
    echo "============================================================"
    echo " RESULTS"
    echo "============================================================"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == PASS* ]]; then
            echo -e "${GREEN}${r}${NC}"
        else
            echo -e "${RED}${r}${NC}"
        fi
    done
    echo
    echo -e "${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}"
    echo

    if (( FAIL_COUNT > 0 )); then
        cat <<'EOF'
TRIAGE for failures:

  1. Confirm the agent is reporting active to the manager:
       kubectl exec -n wazuh wazuh-manager-0 -- /var/ossec/bin/agent_control -lc

  2. Confirm the agent's modules are running on the host:
       /var/ossec/bin/wazuh-control status
     Expect all of: agentd, execd, logcollector, syscheckd, modulesd.

  3. Confirm auditd is running and its rules are loaded (test 3, 5):
       systemctl status auditd
       auditctl -l | head -20

  4. Confirm fail2ban's sshd jail is enabled (test 6):
       fail2ban-client status sshd

  5. The alert ID patterns in this script are conservative — actual rule
     IDs vary by Wazuh version. Inspect the manager's alerts.json directly:
       kubectl exec -n wazuh wazuh-manager-0 -- tail -100 /var/ossec/logs/alerts/alerts.json | less
     If you see relevant events but with different rule IDs, update the
     patterns in this script.

EOF
        exit 1
    fi

    echo "✓ all detection paths verified."
    exit 0
}

main "$@"
