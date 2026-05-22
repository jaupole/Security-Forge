#!/usr/bin/env bash
# Phase 7d.5 (operator-backlog #17 fix) — pre-register the Wazuh agent
# on the manager, extract its enrollment key, and persist as a K8s
# Secret in the wazuh-agent namespace.
#
# Why this is needed:
#   The DaemonSet's /var/ossec/etc/ is an EmptyDir, so the agent's
#   auto-enrolled client.keys is wiped on every pod restart. The agent
#   then re-enrolls; manager's `<after_registration_time>` blocks the
#   re-replacement and the agent gets `Duplicate agent name` rejection
#   forever. With a pre-registered key persisted as a K8s Secret, the
#   init container injects it into client.keys at every pod start —
#   the agent never auto-enrolls, never races against the manager.
#
# What this does:
#   1. Removes ALL existing 'desktop-control-plane' agents from the
#      manager (clean slate).
#   2. Registers a fresh agent named 'desktop-control-plane' (the
#      DaemonSet's spec.nodeName for Docker Desktop's single node).
#   3. Extracts the key (base64-encoded ID + name + IP + key string).
#   4. Reconstructs the full client.keys file content (one line:
#      "<id> <name> <ip> <key>").
#   5. Creates / overwrites K8s Secret wazuh-agent/wazuh-agent-key
#      with the client.keys content as `client.keys` data key.
#
# Idempotent: re-running registers a NEW agent with NEW ID + key,
# overwrites the Secret, restarts the DaemonSet so the new key is
# picked up.
#
# Multi-node note: this script registers ONE agent (single-node
# Docker Desktop). For a multi-node cluster, each node needs its own
# agent name + key. The cleanest multi-node approach is a per-node
# Job that registers via the manager's API; out of scope for local-
# edition.
#
# Usage:
#   bash platform/manifests/wazuh-agent/bootstrap-agent-key.sh
#
# Pre-conditions:
#   - wazuh-manager-0 is up + healthy
#   - wazuh-agent namespace exists (kubectl apply -f
#     platform/manifests/wazuh-agent/01-namespace.yaml first)

set -euo pipefail

NS_MGR=wazuh
MGR_POD=wazuh-manager-0
NS_AGT=wazuh-agent
AGENT_NAME=desktop-control-plane
SECRET_NAME=wazuh-agent-key

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Pre-flight.
kubectl get pod -n "$NS_MGR" "$MGR_POD" >/dev/null || { red "wazuh-manager-0 not found"; exit 1; }
kubectl get ns "$NS_AGT" >/dev/null || { red "wazuh-agent ns missing — apply 01-namespace.yaml first"; exit 1; }

# 2. Clean slate — remove any existing agent with this name.
green "==> removing any existing '$AGENT_NAME' agent registrations"
EXISTING_IDS=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -l 2>/dev/null \
    | awk -v name="$AGENT_NAME" '$0 ~ "Name: "name"," { print $2 }' | tr -d ',' | tr '\n' ' ')
if [ -n "${EXISTING_IDS// /}" ]; then
    for id in $EXISTING_IDS; do
        [ -z "$id" ] && continue
        yellow "    removing existing agent ID $id"
        # The CLI -r prompts for confirmation; pipe 'y' as confirmation.
        printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- /var/ossec/bin/manage_agents -r "$id" >/dev/null 2>&1 || true
    done
else
    green "    (no existing registrations for '$AGENT_NAME')"
fi

# 3. Register fresh agent (non-interactive).
green "==> registering agent '$AGENT_NAME' (IP: any)"
# manage_agents -a <ip> -n <name> creates the agent. ID is auto-assigned.
# It still prompts for confirmation; pipe 'y'.
REGISTER_OUT=$(printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- /var/ossec/bin/manage_agents -a any -n "$AGENT_NAME" 2>&1)
# Output format: "Agent added with ID 008." — extract the trailing digits.
NEW_ID=$(printf '%s' "$REGISTER_OUT" | grep -oE "Agent added with ID [0-9]+" | grep -oE '[0-9]+' | head -1)
if [ -z "$NEW_ID" ]; then
    red "    failed to extract new agent ID. Raw output:"
    red "$REGISTER_OUT"
    exit 1
fi
green "    registered as ID $NEW_ID"

# 4. Extract key (non-interactive).
green "==> extracting key for agent ID $NEW_ID"
KEY_OUT=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -e "$NEW_ID" 2>&1)
# manage_agents -e prints:
#   Agent key information for '<id>' is:
#   <base64-blob>
# The base64 decodes to "<id> <name> <ip> <key>".
B64KEY=$(printf '%s' "$KEY_OUT" | grep -E '^[A-Za-z0-9+/=]{60,}$' | head -1)
if [ -z "$B64KEY" ]; then
    red "    failed to extract base64 key. Raw output:"
    red "$KEY_OUT"
    exit 1
fi

# 5. Decode the base64 key — that gives us the client.keys content
#    (single line: "<id> <name> <ip> <key>").
CLIENT_KEYS=$(printf '%s' "$B64KEY" | base64 -d 2>/dev/null)
if ! printf '%s' "$CLIENT_KEYS" | grep -qE '^[0-9]+ '; then
    red "    decoded key doesn't look like a client.keys line:"
    red "    '$CLIENT_KEYS'"
    exit 1
fi
green "    extracted client.keys line (id=$NEW_ID name=$AGENT_NAME)"

# 6. Create / overwrite K8s Secret.
green "==> writing K8s Secret $NS_AGT/$SECRET_NAME"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
printf '%s\n' "$CLIENT_KEYS" > "$TMPFILE"

kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NS_AGT" \
    --from-file=client.keys="$TMPFILE" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - \
        secforge.platform/component=wazuh-agent \
        app.kubernetes.io/managed-by=bootstrap-agent-key-script \
        --dry-run=client -o yaml \
    | kubectl apply -f -

unset CLIENT_KEYS B64KEY

green ""
green "Agent pre-registration complete. ID=$NEW_ID, Name=$AGENT_NAME"
green ""
green "Next:"
green "  kubectl rollout restart -n $NS_AGT daemonset/wazuh-agent"
green ""
green "Verify post-restart:"
green "  kubectl exec -n $NS_AGT ds/wazuh-agent -c wazuh-agent -- cat /var/ossec/etc/client.keys"
green "  kubectl exec -n $NS_MGR $MGR_POD -- /var/ossec/bin/agent_control -l"
green ""
