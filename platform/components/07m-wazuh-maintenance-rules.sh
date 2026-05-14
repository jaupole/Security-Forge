#!/usr/bin/env bash
# 07m — SecForge maintenance rules + host agent log path extensions.
#
# Adds custom Wazuh rules for the operator-attention events:
#   - OpenBao sealed (100501)
#   - cert-manager renewal failure (100601, 100602)
#   - CNPG cluster degraded (100701)
#   - Velero backup failed (100801)
#   - Wazuh agent disconnected (100900, 100901)
#
# All include `system_admin_attention` so they show up on the Maintenance
# Required dashboard installed by 07l.
#
# Also extends the host wazuh-agent's ossec.conf to tail the pod log paths
# these rules need (cert-manager, postgres-operator, velero, openbao-seal).
#
# Run AFTER 07l-wazuh-upstream-image-rules.sh. Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
RULE_SRC="$PLATFORM_DIR/manifests/wazuh/local-rules/secforge-maintenance.xml"

NS=wazuh
MGR_POD=wazuh-manager-0
RULE_DEST=/var/ossec/etc/rules/local_rules_secforge_maintenance.xml
HOST_OSSEC_CONF=/var/ossec/etc/ossec.conf

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ -f "$RULE_SRC" ] || { red "ERROR: $RULE_SRC not found"; exit 1; }

# 1. Push rules to manager
green "==> [1/4] push secforge-maintenance.xml to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $RULE_DEST" < "$RULE_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $RULE_DEST
  chmod 0640 $RULE_DEST
"

# 2. Validate manager config
green "==> [2/4] validate manager rules"
if ! kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5; then
  red "    rule validation failed; investigate before reloading"
  exit 1
fi

# 3. Reload manager so new rules take effect
green "==> [3/4] reload manager"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -2

# 4. Extend host wazuh-agent ossec.conf with the pod log paths these rules
# need. Idempotent — only adds blocks not already present.
green "==> [4/4] extend host wazuh-agent ossec.conf with pod log tails"

if [ ! -f "$HOST_OSSEC_CONF" ]; then
  yellow "    host wazuh-agent not installed; skipping localfile additions"
  yellow "    (rules are still loaded on manager; they'll fire once an agent feeds matching logs)"
else
  ADDED=0
  add_localfile() {
    local label="$1" path="$2"
    if ! grep -qF "$path" "$HOST_OSSEC_CONF"; then
      # Insert before </ossec_config> closing tag
      sudo sed -i "/^<\/ossec_config>/i \\
\\
  <localfile>\\
    <log_format>syslog</log_format>\\
    <location>$path</location>\\
    <label key=\"source\">$label</label>\\
  </localfile>" "$HOST_OSSEC_CONF"
      ADDED=$((ADDED + 1))
      yellow "    + added: $path"
    fi
  }

  # Need sudo for the sed; this script must run as root anyway
  if [ "$EUID" -ne 0 ]; then
    red "    must run as root to modify $HOST_OSSEC_CONF"
    red "    re-run with sudo"
    exit 1
  fi

  add_localfile openbao-seal '/var/log/pods/openbao_openbao-seal-*/openbao/*.log'
  add_localfile cert-manager '/var/log/pods/cert-manager_cert-manager-*/cert-manager-controller/*.log'
  add_localfile cnpg-operator '/var/log/pods/postgres-operator_*/manager/*.log'
  add_localfile velero       '/var/log/pods/velero_velero-*/velero/*.log'

  if [ "$ADDED" -gt 0 ]; then
    yellow "    restarting host wazuh-agent to pick up $ADDED new log path(s)"
    systemctl restart wazuh-agent
  else
    yellow "    all required log paths already monitored"
  fi
fi

cat <<EOF

✓ Maintenance rules installed.

Rule IDs added:
  100500/100501  OpenBao sealed
  100600/100601/100602  cert-manager renewal failures
  100700/100701  CNPG cluster degraded
  100800/100801  Velero backup failed
  100900/100901  Wazuh agent disconnected (overrides built-in 503)

All level≥8 alerts include the meta-group \`system_admin_attention\` and
will appear on the Maintenance Required dashboard.

Test by injecting a synthetic log:
  logger -t openbao -p daemon.warning "TEST: vault is sealed"

Wait ~10s, then in the Wazuh dashboard:
  - Discover view filtered on rule.id: 100501
  - Maintenance Required dashboard: should show 1 new alert
EOF
