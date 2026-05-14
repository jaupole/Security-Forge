#!/usr/bin/env bash
# 07k — Create the Wazuh `k8s` agent group + push centralized config.
#
# The wazuh-agent DaemonSet is configured (in 04-daemonset.yaml) to
# register agents into groups `default,k8s`. This component:
#   1. Creates the k8s group on the wazuh-manager (idempotent).
#   2. Pushes platform/manifests/wazuh-agent/k8s-group-agent.conf into
#      /var/ossec/etc/shared/k8s/agent.conf on the manager.
#   3. Reloads the manager so the new config propagates to all agents
#      currently in the k8s group.
#   4. Purges stale SCA results for any pod-DaemonSet agents (the
#      cis_amazon_linux_2023 policy whose checks make no sense in a
#      containerized agent context).
#
# Run AFTER 07-wazuh.sh + the wazuh-agent DaemonSet is running.
# Idempotent — safe to re-run.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
SRC_CONF="$PLATFORM_DIR/manifests/wazuh-agent/k8s-group-agent.conf"

if [ ! -f "$SRC_CONF" ]; then
  echo "ERROR: $SRC_CONF not found" >&2
  exit 1
fi

NS=wazuh
MGR_POD=wazuh-manager-0
GROUP=k8s

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# 1. Create k8s group on manager (idempotent — the agent_groups -a -g
# command exits 0 even if the group already exists, but guard anyway).
green "==> [1/4] ensure wazuh agent group: $GROUP"
if kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
     test -d "/var/ossec/etc/shared/$GROUP" 2>/dev/null; then
  yellow "    group '$GROUP' already exists"
else
  kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
    /var/ossec/bin/agent_groups -a -g "$GROUP" -q 2>&1 | tail -1
fi

# 2. Push agent.conf for the k8s group.
green "==> [2/4] push k8s-group-agent.conf to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > /var/ossec/etc/shared/$GROUP/agent.conf" < "$SRC_CONF"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh /var/ossec/etc/shared/$GROUP/agent.conf
  chmod 0660 /var/ossec/etc/shared/$GROUP/agent.conf
"
yellow "    /var/ossec/etc/shared/$GROUP/agent.conf installed"

# 3. Add any wazuh-agent pods (group=k8s in their env) to the group on
# the manager. The agent itself reports its desired groups at registration
# time, but on existing registered agents we ensure membership explicitly.
green "==> [3/4] ensure pod-DaemonSet agents are members of $GROUP"
for agent_id in $(kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
                    /var/ossec/bin/agent_control -ls 2>/dev/null \
                  | awk -F, '$2 ~ /-k8s$|^secforge-prod-k8s/ {print $1}'); do
  kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
    /var/ossec/bin/agent_groups -a -i "$agent_id" -g "$GROUP" -q 2>&1 | tail -1
done

# 4. Reload manager so new shared config is pushed; purge any stale SCA
# results from pod-DaemonSet agent DBs (these were collected BEFORE we
# disabled the SCA module and would otherwise haunt the dashboard).
green "==> [4/4] reload manager + purge stale cis_amazon_linux_2023 SCA"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  /var/ossec/bin/wazuh-control reload 2>&1 | tail -1

# Find pod-DaemonSet agent IDs and purge their SCA caches via Python sqlite3
# (sqlite3 binary isn't in the container; python3 is).
for agent_id in $(kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- \
                    /var/ossec/bin/agent_control -ls 2>/dev/null \
                  | awk -F, '$2 ~ /-k8s$|^secforge-prod-k8s/ {print $1}'); do
  yellow "    purging stale SCA cache for agent $agent_id"
  kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- python3 -c "
import sqlite3, sys
conn = sqlite3.connect('/var/ossec/queue/db/${agent_id}.db')
c = conn.cursor()
for tbl, where in [
    ('sca_check_compliance', 'id_check IN (SELECT id FROM sca_check WHERE policy_id LIKE \"cis_amazon%\")'),
    ('sca_check_rules',      'id_check IN (SELECT id FROM sca_check WHERE policy_id LIKE \"cis_amazon%\")'),
    ('sca_check',            'policy_id LIKE \"cis_amazon%\"'),
    ('sca_policy',           'id LIKE \"cis_amazon%\"'),
    ('sca_scan_info',        'policy_id LIKE \"cis_amazon%\"'),
]:
    c.execute(f'DELETE FROM {tbl} WHERE {where}')
conn.commit()
conn.close()
" 2>/dev/null || yellow "    (no SCA tables / agent DB; skipping $agent_id)"
done

cat <<EOF

✓ wazuh k8s group configured.

Verify:
  kubectl exec -n wazuh wazuh-manager-0 -c wazuh-manager -- \\
    cat /var/ossec/etc/shared/k8s/agent.conf

  # Bounce a pod agent to pick up new config:
  kubectl delete pod -n wazuh-agent -l app.kubernetes.io/name=wazuh-agent

  # Confirm SCA disabled on the agent:
  kubectl exec -n wazuh-agent <pod> -- grep -A1 'sca:' /var/ossec/logs/ossec.log | tail
  # Expect: 'sca: INFO: Module disabled. Exiting.'
EOF
