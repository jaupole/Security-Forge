#!/usr/bin/env bash
# 07b — Wazuh agent (hardened DaemonSet in wazuh-agent namespace).
#
# Deploys a Wazuh agent that monitors the underlying host OS via hostPath
# mounts (/etc, /var/log, /usr/{bin,sbin}, /home, /root, /boot). Reports
# events to the in-cluster wazuh-manager.
#
# OS-level threats this catches:
#   - SSH login activity (parses /var/log/auth.log)
#   - sudo / privilege escalation
#   - File integrity monitoring (FIM): /etc, /bin, /usr/bin, ~/.ssh, etc.
#   - Rootkit indicators (built-in rootcheck module)
#   - New users / groups (watches /etc/passwd, /etc/group, /etc/shadow)
#   - Kernel module loads (suspicious modules)
#   - Vulnerability scans (dpkg inventory vs CVE database)
#   - Auditd integration (syscall-level visibility)
#
# Pre-conditions:
#   - 07-wazuh.sh ran (manager is up)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/wazuh-agent"

# Adapt agent name for our node (was "desktop-control-plane" in local edition).
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
AGENT_NAME="${NODE_NAME}"

NS_MGR=wazuh
NS_AGT=wazuh-agent
MGR_POD=wazuh-manager-0
SECRET_NAME=wazuh-agent-key

# 1. Namespace + RBAC + ConfigMap (from local-edition manifests, edition label patched at apply time)
echo ">>> Applying namespace + RBAC + ConfigMap + NetworkPolicies"
kubectl apply -f "$M/01-namespace.yaml"
kubectl apply -f "$M/02-rbac.yaml"
kubectl apply -f "$M/03-configmap.yaml"
kubectl apply -f "$M/05-networkpolicies.yaml"

# 2. Pre-register agent + persist client.keys as Secret (idempotent — re-running
# rotates the key).
kubectl get pod -n "$NS_MGR" "$MGR_POD" >/dev/null || { echo "ERROR: $MGR_POD not running" >&2; exit 1; }

echo ">>> Removing any existing registrations for '$AGENT_NAME'"
EXISTING_IDS=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -l 2>/dev/null \
  | awk -v name="$AGENT_NAME" '$0 ~ "Name: "name"," { print $2 }' | tr -d ',' | tr '\n' ' ')
if [[ -n "${EXISTING_IDS// /}" ]]; then
  for id in $EXISTING_IDS; do
    [[ -z "$id" ]] && continue
    echo "    removing existing agent ID $id"
    printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- /var/ossec/bin/manage_agents -r "$id" >/dev/null 2>&1 || true
  done
else
  echo "    no existing registrations for '$AGENT_NAME'"
fi

echo ">>> Registering fresh agent '$AGENT_NAME'"
REGISTER_OUT=$(printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- /var/ossec/bin/manage_agents -a any -n "$AGENT_NAME" 2>&1)
NEW_ID=$(printf '%s' "$REGISTER_OUT" | grep -oE "Agent added with ID [0-9]+" | grep -oE '[0-9]+' | head -1)
if [[ -z "$NEW_ID" ]]; then
  echo "ERROR: failed to extract new agent ID. Raw:" >&2
  echo "$REGISTER_OUT" >&2
  exit 1
fi
echo "    registered as ID $NEW_ID"

echo ">>> Extracting agent key"
KEY_OUT=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -e "$NEW_ID" 2>&1)
B64KEY=$(printf '%s' "$KEY_OUT" | grep -E '^[A-Za-z0-9+/=]{60,}$' | head -1)
if [[ -z "$B64KEY" ]]; then
  echo "ERROR: failed to extract base64 key. Raw:" >&2
  echo "$KEY_OUT" >&2
  exit 1
fi

CLIENT_KEYS=$(printf '%s' "$B64KEY" | base64 -d 2>/dev/null)
if ! printf '%s' "$CLIENT_KEYS" | grep -qE '^[0-9]+ '; then
  echo "ERROR: decoded key doesn't look like a client.keys line: '$CLIENT_KEYS'" >&2
  exit 1
fi

echo ">>> Persisting client.keys as Secret $NS_AGT/$SECRET_NAME"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$CLIENT_KEYS" > "$TMP"
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NS_AGT" \
  --from-file=client.keys="$TMP" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - \
      secforge.platform/component=wazuh-agent \
      app.kubernetes.io/managed-by=bootstrap-agent-key-script \
      --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
unset CLIENT_KEYS B64KEY

# 3. Apply DaemonSet (or restart if already exists, to pick up new key)
echo ">>> Applying DaemonSet"
kubectl apply -f "$M/04-daemonset.yaml"

# Restart in case the DS was already running with an old key
kubectl -n "$NS_AGT" rollout restart daemonset/wazuh-agent 2>/dev/null || true

echo ">>> Waiting for agent DaemonSet to be Ready"
kubectl -n "$NS_AGT" rollout status daemonset/wazuh-agent --timeout=300s

echo ">>> Verifying agent is connected to manager"
sleep 10
kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/agent_control -l 2>&1 | head -10

cat <<EOF

✓ Wazuh agent deployed.
  Agent name: $AGENT_NAME (ID $NEW_ID)
  Namespace:  $NS_AGT (PSS=privileged for hostPath access)

Verify host events flowing:
  1. From the box, do something logged: \`sudo ls /etc/shadow\`
  2. In the dashboard (https://wazuh.secforge.dev), Discover view should
     surface the event within a few seconds.
  3. Run \`agent_control -l\` on the manager to see agent state.
EOF
