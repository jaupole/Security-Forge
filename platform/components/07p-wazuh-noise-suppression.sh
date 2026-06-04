#!/usr/bin/env bash
# 07p — SecForge Wazuh noise-suppression rules + host agent buffer sizing.
#
# Security-audit follow-up (2026-06-04, Wazuh triage). Tunes three high-volume
# benign/false-positive sources and raises the host agent's event buffer so
# bursts stop dropping events.
#
#   Manager rules (100200-100202): promiscuous-mode on CNI virtual interfaces,
#   dockerd CI exec errors, and 401 false-positives from the Trivy findings log.
#
#   Host agent client_buffer: queue_size 5000->20000, events_per_second
#   500->1000 (was overrunning -> "Agent event queue is full").
#
# Run AFTER 07m-wazuh-maintenance-rules.sh. Idempotent. Must run as root
# (edits the host /var/ossec/etc/ossec.conf).

set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
RULE_SRC="$PLATFORM_DIR/manifests/wazuh/local-rules/secforge-noise-suppression.xml"

NS=wazuh
MGR_POD=wazuh-manager-0
RULE_DEST=/var/ossec/etc/rules/local_rules_secforge_noise_suppression.xml
HOST_OSSEC_CONF=/var/ossec/etc/ossec.conf

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ -f "$RULE_SRC" ] || { red "ERROR: $RULE_SRC not found"; exit 1; }

# 1. Push suppression rules to manager
green "==> [1/4] push secforge-noise-suppression.xml to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "cat > $RULE_DEST" < "$RULE_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "chown wazuh:wazuh $RULE_DEST; chmod 0640 $RULE_DEST"

# 2. Validate manager ruleset (fails closed — do not reload a broken ruleset)
green "==> [2/4] validate manager rules (wazuh-analysisd -t)"
if ! kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5; then
  red "    rule validation FAILED; removing the new file and aborting"
  kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- rm -f "$RULE_DEST" || true
  exit 1
fi

# 3. Reload manager so the new rules take effect
green "==> [3/4] reload manager"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -2

# 4. Raise the host agent's client_buffer (idempotent — only if values differ)
green "==> [4/4] raise host wazuh-agent client_buffer"
if [ ! -f "$HOST_OSSEC_CONF" ]; then
  yellow "    host wazuh-agent not installed; skipping buffer change"
elif [ "$EUID" -ne 0 ]; then
  red "    must run as root to edit $HOST_OSSEC_CONF — re-run with sudo"; exit 1
else
  CHANGED=0
  if grep -q '<queue_size>5000</queue_size>' "$HOST_OSSEC_CONF"; then
    sed -i 's#<queue_size>5000</queue_size>#<queue_size>20000</queue_size>#' "$HOST_OSSEC_CONF"; CHANGED=1
  fi
  if grep -q '<events_per_second>500</events_per_second>' "$HOST_OSSEC_CONF"; then
    sed -i 's#<events_per_second>500</events_per_second>#<events_per_second>1000</events_per_second>#' "$HOST_OSSEC_CONF"; CHANGED=1
  fi
  if [ "$CHANGED" -eq 1 ]; then
    yellow "    client_buffer raised to 20000/1000 — restarting wazuh-agent"
    systemctl restart wazuh-agent
  else
    yellow "    client_buffer already at target values"
  fi
fi

green "✓ Noise-suppression rules + buffer sizing applied (rule IDs 100100-100102)."
