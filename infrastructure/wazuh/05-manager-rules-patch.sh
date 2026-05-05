#!/usr/bin/env bash
# Phase 7d.6 (operator-backlog #18 closeout) — patch the wazuh-manager
# StatefulSet (chart-managed) to mount the secforge_local_rules.xml
# ConfigMap at /var/ossec/etc/rules/secforge_local_rules.xml. The
# manager's <ruleset><rule_dir>etc/rules</rule_dir></ruleset> block
# auto-loads any .xml file in that directory; no ossec.conf edit
# required.
#
# Sibling to 04-manager-decoders-patch.sh — same strategic-merge
# patch idiom, different mount target.
#
# Idempotent: re-running re-applies the patch and rolls the manager.
#
# Pre-conditions:
#   - infrastructure/wazuh/04-rules-configmap.yaml applied
#     (creates ConfigMap wazuh-manager-local-rules).
#
# Usage:
#   bash infrastructure/wazuh/05-manager-rules-patch.sh

set -euo pipefail

NS=wazuh
STS=wazuh-manager

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! kubectl get cm -n "$NS" wazuh-manager-local-rules >/dev/null 2>&1; then
    red "ConfigMap $NS/wazuh-manager-local-rules not found."
    red "Apply infrastructure/wazuh/04-rules-configmap.yaml first."
    exit 1
fi

# 1. Patch the StatefulSet — add a volume + mount via strategic merge.
#    Strategic merge is keyed on volume.name + volumeMount.name, so this
#    composes cleanly with 04-manager-decoders-patch.sh's prior patch
#    (which adds `local-decoders` volume + mount). Re-applying either
#    patch only updates the entries it owns.
green "==> patching $NS/$STS to mount secforge_local_rules.xml"
kubectl -n "$NS" patch sts "$STS" --type=strategic --patch "$(cat <<'EOF'
spec:
  template:
    spec:
      volumes:
        - name: local-rules
          configMap:
            name: wazuh-manager-local-rules
      containers:
        - name: wazuh-manager
          volumeMounts:
            - name: local-rules
              mountPath: /var/ossec/etc/rules/secforge_local_rules.xml
              subPath: secforge_local_rules.xml
              readOnly: true
EOF
)" 2>&1 | tail -3

# 2. Roll the manager so the new mount takes effect + analysisd
#    re-loads ruleset/.
green "==> rolling-restarting $NS/$STS"
kubectl -n "$NS" rollout restart sts "$STS"

green ""
green "Rules patch applied. Verify post-roll:"
green "  kubectl exec -n $NS ${STS}-0 -- ls -la /var/ossec/etc/rules/secforge_local_rules.xml"
green "  kubectl exec -n $NS ${STS}-0 -- /var/ossec/bin/wazuh-logtest <<'JSON'"
green "  {\"time\":\"2026-05-05T13:00:00Z\",\"type\":\"request\",\"auth\":{\"display_name\":\"test\"},\"request\":{\"operation\":\"read\",\"path\":\"secret/foo\"}}"
green "  JSON"
green ""
