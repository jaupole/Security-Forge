#!/usr/bin/env bash
# 07q — GitHub Actions self-hosted runner crash-loop detection rules.
#
# Installs Wazuh manager rules that fire when a runner unit enters a SessionConflict
# restart loop (full incident context in manifests/wazuh/local-rules/github-runner.xml).
# The host wazuh-agent already forwards journald, so no localfile additions are needed.
#
# Rule IDs:
#   100210  runner unit auto-restarted by systemd   (base,       level 3)
#   100211  runner session conflict                 (base,       level 3)
#   100212  runner CRASH-LOOPING (3+ in 15m)        (escalation, level 12, system_admin_attention)
#
# Idempotent. Safe to re-run. Run as root (kubectl/k3s access).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
RULE_SRC="$PLATFORM_DIR/manifests/wazuh/local-rules/github-runner.xml"
NS=wazuh
RULE_DEST=/var/ossec/etc/rules/local_rules_github_runner.xml

if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"; else KUBECTL="k3s kubectl"; fi

[ -f "$RULE_SRC" ] || { echo "ERROR: $RULE_SRC not found" >&2; exit 1; }

MGR_POD="$($KUBECTL get pods -n "$NS" -o name 2>/dev/null | grep -oE 'wazuh-manager-[0-9]+' | head -1)"
[ -n "$MGR_POD" ] || { echo "ERROR: wazuh manager pod not found" >&2; exit 1; }

echo "==> [1/3] push github-runner.xml to $MGR_POD"
$KUBECTL exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "cat > $RULE_DEST" < "$RULE_SRC"
$KUBECTL exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "chown wazuh:wazuh $RULE_DEST && chmod 0640 $RULE_DEST"

echo "==> [2/3] validate manager rules"
if ! $KUBECTL exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5; then
  echo "    rule validation FAILED; not reloading" >&2
  exit 1
fi

echo "==> [3/3] reload manager"
$KUBECTL exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -2

echo "OK: GitHub runner crash-loop rules installed (100210-100212)."
