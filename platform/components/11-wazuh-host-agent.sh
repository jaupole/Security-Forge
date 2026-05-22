#!/usr/bin/env bash
# 11 — Wazuh agent (native install on the bare-metal host).
#
# Replaces the in-cluster DaemonSet pattern (07b-wazuh-agent.sh) with a
# native systemd-managed agent. Several Wazuh modules hardcode literal paths
# (/var/lib/dpkg/status, /etc/passwd, etc.) and don't honour the /host/*
# indirection the DaemonSet relied on, so a native install is the only way
# to get full host visibility (network interfaces, processes, packages,
# rootcheck, SCA, auditd integration).
#
# See platform/manifests/wazuh-host-agent/README.md for the full design
# rationale and out-of-scope list.
#
# Pre-conditions:
#   - 07-wazuh.sh ran (manager + indexer + dashboard live in cluster)
#   - This script runs ON the bare-metal host (NOT from a workstation)
#   - kubectl is configured against the local k3s cluster
#     (default: /etc/rancher/k3s/k3s.yaml; the ops user must be in the
#     k3s group, or KUBECONFIG explicitly set)
#   - Run as root, or via sudo (apt + systemctl + writes under /var/ossec/
#     all need root)
#
# What this does (in order):
#   1. Sanity-check we're on a Linux host with apt + systemd + kubectl
#   2. Add the Wazuh apt repo + GPG key (idempotent; pinned key fingerprint)
#   3. Install wazuh-agent at the pinned version
#   4. Render ossec.conf from the template via envsubst
#   5. Register agent with the in-cluster manager, write client.keys
#   6. Enable + start the systemd unit
#   7. Wait for "Active" status from the manager
#   8. Tear down the in-cluster DaemonSet (gated on step 7 succeeding)
#
# Idempotent: re-running will deregister + re-register the agent (rotates
# the client.keys), re-render ossec.conf (preserving any operator edits ONLY
# inside the explicit <ossec_config> sections at the bottom — see template
# header for rules), and re-start the systemd unit.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests/wazuh-host-agent"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

# ── Configuration ─────────────────────────────────────────────────────────

# Pin to a major.minor matching the in-cluster manager (Phase 7 deploys
# 4.14.x via the vendored chart). Wazuh DOES NOT support cross-major
# agent/manager combinations.
AGENT_VERSION_PIN="4.14.4-1"

# Where the agent connects. We use 127.0.0.1 + NodePort instead of the
# ClusterIP DNS name because:
#   - The host's resolver doesn't know about CoreDNS (cluster.local
#     names don't resolve from outside the pod network).
#   - kube-proxy DOES set up iptables rules for the ClusterIP itself,
#     but resolving the FQDN to that IP requires DNS access we don't have.
#   - NodePort 31514/31515 are bound on every node interface including
#     loopback; localhost works trivially.
# This is the same approach used to enroll via authd at :31515.
# A separate NodePort Service (manifests/wazuh/standalone/wazuh-manager-nodeport.yaml)
# exposes manager 1514/1515 as 31514/31515. ensure_manager_nodeport() applies it.
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-127.0.0.1}"
WAZUH_MANAGER_PORT="${WAZUH_MANAGER_PORT:-31514}"

# Cluster-side identifiers (must match Phase 7 deployment)
NS_MGR=wazuh
MGR_POD=wazuh-manager-0

# Daemonset cleanup targets (matches 07b-wazuh-agent.sh's outputs)
NS_AGT=wazuh-agent
DS_NAME=wazuh-agent

# ── Sanity checks ─────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: must run as root (need apt + systemctl + writes under /var/ossec)" >&2
        echo "Try: sudo bash $0" >&2
        exit 1
    fi
}

require_host_tools() {
    for cmd in apt-get systemctl envsubst kubectl curl gpg; do
        if ! command -v "$cmd" >/dev/null; then
            echo "ERROR: required command not found: $cmd" >&2
            [[ "$cmd" == "envsubst" ]] && echo "  install with: apt install gettext-base" >&2
            exit 1
        fi
    done
}

require_cluster_access() {
    if ! kubectl -n "$NS_MGR" get pod "$MGR_POD" >/dev/null 2>&1; then
        echo "ERROR: cannot reach $NS_MGR/$MGR_POD via kubectl" >&2
        echo "  KUBECONFIG=${KUBECONFIG:-(unset; default ~/.kube/config or /etc/rancher/k3s/k3s.yaml)}" >&2
        exit 1
    fi
}

# ── 2. Wazuh apt repo + GPG key ───────────────────────────────────────────

ensure_apt_repo() {
    local key_path=/etc/apt/keyrings/wazuh.gpg
    local key_url="https://packages.wazuh.com/key/GPG-KEY-WAZUH"
    local repo_path=/etc/apt/sources.list.d/wazuh.list
    # SHA-256 fingerprint of the Wazuh signing key — pin to detect MITM.
    # Verify against https://documentation.wazuh.com/ if rotated upstream.
    local expected_fingerprint="0DCFCA5547B19D2A6099506096B3EE5F29111145"

    if [[ ! -f "$key_path" ]]; then
        echo ">>> Adding Wazuh GPG key to $key_path"
        mkdir -p "$(dirname "$key_path")"
        curl -fsSL "$key_url" | gpg --dearmor -o "$key_path"
        chmod 644 "$key_path"
    fi

    local actual_fingerprint
    actual_fingerprint=$(gpg --no-default-keyring --keyring "$key_path" --list-keys --with-colons \
        | awk -F: '/^fpr:/ {print $10; exit}')
    if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
        echo "ERROR: Wazuh GPG key fingerprint mismatch" >&2
        echo "  expected: $expected_fingerprint" >&2
        echo "  got:      $actual_fingerprint" >&2
        echo "  refusing to proceed — possible MITM or upstream rotation. Verify and update the pin." >&2
        exit 1
    fi

    if [[ ! -f "$repo_path" ]] || ! grep -q "packages.wazuh.com" "$repo_path"; then
        echo ">>> Adding Wazuh apt source to $repo_path"
        echo "deb [signed-by=$key_path] https://packages.wazuh.com/4.x/apt/ stable main" \
            > "$repo_path"
    fi

    echo ">>> apt-get update"
    apt-get update -qq
}

# ── 3. Install wazuh-agent ────────────────────────────────────────────────

install_agent_pkg() {
    local installed
    installed=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || true)
    if [[ "$installed" == "$AGENT_VERSION_PIN" ]]; then
        echo ">>> wazuh-agent $AGENT_VERSION_PIN already installed"
        return
    fi
    if [[ -n "$installed" ]]; then
        echo ">>> Replacing wazuh-agent $installed → $AGENT_VERSION_PIN"
    else
        echo ">>> Installing wazuh-agent $AGENT_VERSION_PIN"
    fi
    # Hold to prevent unattended-upgrades from drifting; explicit `apt install`
    # below will still apply the pinned version.
    DEBIAN_FRONTEND=noninteractive apt-get install -y "wazuh-agent=$AGENT_VERSION_PIN"
    apt-mark hold wazuh-agent >/dev/null
}

# ── 4. Render ossec.conf ──────────────────────────────────────────────────

render_ossec_conf() {
    local target=/var/ossec/etc/ossec.conf
    local template="$M/ossec.conf.template"

    [[ -f "$template" ]] || { echo "ERROR: template missing: $template" >&2; exit 1; }

    # Back up the existing file once (first run); subsequent runs overwrite
    # the .secforge-rendered marker so we know envsubst was the source.
    if [[ -f "$target" ]] && [[ ! -f "$target.preinstall.bak" ]]; then
        cp "$target" "$target.preinstall.bak"
        echo ">>> Backed up original ossec.conf to ${target}.preinstall.bak"
    fi

    echo ">>> Rendering ossec.conf via envsubst"
    HOSTNAME="${HOSTNAME:-$(hostname)}" \
    WAZUH_MANAGER_HOST="$WAZUH_MANAGER_HOST" \
    WAZUH_MANAGER_PORT="$WAZUH_MANAGER_PORT" \
        envsubst '${HOSTNAME} ${WAZUH_MANAGER_HOST} ${WAZUH_MANAGER_PORT}' \
        < "$template" > "$target"

    chown root:wazuh "$target"
    chmod 0640 "$target"
}

# ── 5. Register with manager ──────────────────────────────────────────────

register_agent() {
    local agent_name="$HOSTNAME"
    [[ -z "$agent_name" || "$agent_name" == "localhost" ]] && agent_name=$(hostname)

    echo ">>> Removing any existing registrations for '$agent_name'"
    local existing_ids
    existing_ids=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -l 2>/dev/null \
        | awk -v name="$agent_name" '$0 ~ "Name: "name"," { print $2 }' | tr -d ',' | tr '\n' ' ')
    if [[ -n "${existing_ids// /}" ]]; then
        for id in $existing_ids; do
            [[ -z "$id" ]] && continue
            echo "    removing existing agent ID $id"
            printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- \
                /var/ossec/bin/manage_agents -r "$id" >/dev/null 2>&1 || true
        done
    fi

    echo ">>> Registering agent '$agent_name'"
    local register_out new_id
    register_out=$(printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- \
        /var/ossec/bin/manage_agents -a any -n "$agent_name" 2>&1)
    new_id=$(printf '%s' "$register_out" | grep -oE "Agent added with ID [0-9]+" | grep -oE '[0-9]+' | head -1)
    if [[ -z "$new_id" ]]; then
        echo "ERROR: failed to register. Manager output:" >&2
        echo "$register_out" >&2
        exit 1
    fi
    echo "    registered as ID $new_id"

    echo ">>> Extracting agent key"
    local key_out b64key client_keys_line
    key_out=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -e "$new_id" 2>&1)
    b64key=$(printf '%s' "$key_out" | grep -E '^[A-Za-z0-9+/=]{60,}$' | head -1)
    [[ -z "$b64key" ]] && { echo "ERROR: failed to extract key. Raw: $key_out" >&2; exit 1; }
    client_keys_line=$(printf '%s' "$b64key" | base64 -d 2>/dev/null)

    echo ">>> Writing /var/ossec/etc/client.keys"
    install -m 0640 -o root -g wazuh /dev/null /var/ossec/etc/client.keys
    printf '%s\n' "$client_keys_line" > /var/ossec/etc/client.keys

    unset b64key client_keys_line
}

# ── 6. systemd ────────────────────────────────────────────────────────────

start_agent_unit() {
    echo ">>> Enabling + starting wazuh-agent.service"
    systemctl daemon-reload
    systemctl enable wazuh-agent >/dev/null 2>&1 || true
    systemctl restart wazuh-agent
    sleep 3
    systemctl --no-pager --lines=5 status wazuh-agent || true
}

# ── 7. Verify reporting Active ────────────────────────────────────────────

wait_for_active() {
    local agent_name="${HOSTNAME:-$(hostname)}"
    echo ">>> Waiting for agent to report Active to manager"
    local elapsed=0
    while (( elapsed < 60 )); do
        if kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/agent_control -lc 2>/dev/null \
                | grep -E "$agent_name.*Active" >/dev/null; then
            echo "    Active."
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    echo "WARNING: agent did not reach Active within 60s." >&2
    echo "  Inspect: kubectl exec -n $NS_MGR $MGR_POD -- /var/ossec/bin/agent_control -lc" >&2
    echo "  Inspect: journalctl -u wazuh-agent -n 50" >&2
    return 1
}

# ── 8. Tear down the in-cluster DaemonSet ─────────────────────────────────

teardown_daemonset() {
    if ! kubectl get ns "$NS_AGT" >/dev/null 2>&1; then
        echo ">>> Old DaemonSet namespace $NS_AGT not present — nothing to tear down"
        return
    fi

    echo ">>> Deleting in-cluster DaemonSet $NS_AGT/$DS_NAME (superseded by native agent)"
    kubectl -n "$NS_AGT" delete daemonset "$DS_NAME" --ignore-not-found
    kubectl -n "$NS_AGT" delete configmap wazuh-agent-ossec-conf --ignore-not-found
    kubectl -n "$NS_AGT" delete secret wazuh-agent-key --ignore-not-found
    kubectl -n "$NS_AGT" delete sa wazuh-agent --ignore-not-found
    kubectl delete clusterrole wazuh-agent --ignore-not-found
    kubectl delete clusterrolebinding wazuh-agent --ignore-not-found

    # Also deregister the DaemonSet's old agent ID from the manager so it
    # stops appearing as Disconnected. The DaemonSet registered as the
    # node name; this script registered as $HOSTNAME. They may differ on
    # multi-word hostnames or when the node name was overridden.
    local node_name old_id
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$node_name" && "$node_name" != "$HOSTNAME" ]]; then
        old_id=$(kubectl exec -n "$NS_MGR" "$MGR_POD" -- /var/ossec/bin/manage_agents -l 2>/dev/null \
            | awk -v name="$node_name" '$0 ~ "Name: "name"," { print $2 }' | tr -d ',' | head -1)
        if [[ -n "$old_id" ]]; then
            echo "    deregistering old DaemonSet agent ID $old_id (was '$node_name')"
            printf 'y\n' | kubectl exec -n "$NS_MGR" "$MGR_POD" -i -- \
                /var/ossec/bin/manage_agents -r "$old_id" >/dev/null 2>&1 || true
        fi
    fi

    # Optional: delete the namespace itself. Left as comment for safety —
    # operator can run manually after confirming nothing else lives there.
    # kubectl delete ns "$NS_AGT" --ignore-not-found
    echo "    NOTE: namespace $NS_AGT left in place (delete manually after confirming empty)"
    echo "          kubectl delete ns $NS_AGT"
    echo "    NOTE: 07b-wazuh-agent.sh should be removed from platform/components/"
    echo "          so install-all.sh stops re-deploying the DaemonSet on every run."
}

# ── Main ──────────────────────────────────────────────────────────────────

ensure_manager_nodeport() {
    local manifest="$PLATFORM_DIR/manifests/wazuh/standalone/wazuh-manager-nodeport.yaml"
    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: NodePort manifest not found at $manifest" >&2
        exit 1
    fi
    echo ">>> Applying wazuh-manager-nodeport Service (exposes 31514/31515 on localhost)"
    kubectl apply -f "$manifest" >/dev/null
}

main() {
    require_root
    require_host_tools
    require_cluster_access
    ensure_manager_nodeport

    ensure_apt_repo
    install_agent_pkg
    register_agent
    render_ossec_conf
    start_agent_unit

    if wait_for_active; then
        teardown_daemonset
    else
        echo ""
        echo "SKIPPING DaemonSet teardown — native agent did not reach Active."
        echo "Investigate before re-running. The DaemonSet is left in place so"
        echo "you don't lose host monitoring while debugging."
        exit 1
    fi

    cat <<EOF

✓ Component 11 — native Wazuh agent installed and reporting.

  Agent name:       ${HOSTNAME:-$(hostname)}
  Manager:          $WAZUH_MANAGER_HOST:$WAZUH_MANAGER_PORT
  Config:           /var/ossec/etc/ossec.conf
  Logs:             /var/ossec/logs/ossec.log
  Service status:   systemctl status wazuh-agent
  Manager view:     kubectl exec -n $NS_MGR $MGR_POD -- /var/ossec/bin/agent_control -lc

Next:
  - bash $SCRIPT_DIR/11a-auditd.sh    (process-level visibility)
  - bash $SCRIPT_DIR/11b-fail2ban.sh  (auto-ban on SSH brute force)

Verification (after 10a + 10b):
  sudo bash $M/verify-detection.sh

EOF
}

main "$@"
