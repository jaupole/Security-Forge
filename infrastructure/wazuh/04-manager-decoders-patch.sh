#!/usr/bin/env bash
# Phase 7d.6 (operator-backlog #18 fix) — patch the wazuh-manager
# StatefulSet (chart-managed) to mount the local_decoder.xml ConfigMap
# at /var/ossec/etc/decoders/local_decoder.xml. The chart doesn't
# expose an extraVolumes hook for the manager, so we apply via
# kubectl patch + roll the StatefulSet.
#
# Idempotent: re-running re-applies the patch (kubectl patch is
# stable) and re-rolls the manager.
#
# Pre-conditions:
#   - infrastructure/wazuh/03-decoders-configmap.yaml applied
#     (creates ConfigMap wazuh-manager-local-decoders).
#
# Usage:
#   bash infrastructure/wazuh/04-manager-decoders-patch.sh

set -euo pipefail

NS=wazuh
STS=wazuh-manager

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Sanity check: ConfigMap exists.
if ! kubectl get cm -n "$NS" wazuh-manager-local-decoders >/dev/null 2>&1; then
    red "ConfigMap $NS/wazuh-manager-local-decoders not found."
    red "Apply infrastructure/wazuh/03-decoders-configmap.yaml first."
    exit 1
fi

# 1. Patch the StatefulSet — add volume + mount via strategic merge.
green "==> patching $NS/$STS to mount local_decoder.xml"
kubectl -n "$NS" patch sts "$STS" --type=strategic --patch "$(cat <<'EOF'
spec:
  template:
    spec:
      volumes:
        - name: local-decoders
          configMap:
            name: wazuh-manager-local-decoders
      containers:
        - name: wazuh-manager
          volumeMounts:
            - name: local-decoders
              mountPath: /var/ossec/etc/decoders/local_decoder.xml
              subPath: local_decoder.xml
              readOnly: true
EOF
)" 2>&1 | tail -3

# 2. Force a roll so the new mount takes effect.
green "==> rolling-restarting $NS/$STS"
kubectl -n "$NS" rollout restart sts "$STS"

green ""
green "Decoder patch applied. Manager will pick up local_decoder.xml on"
green "next restart. Verify with:"
green "  kubectl exec -n $NS ${STS}-0 -- ls -la /var/ossec/etc/decoders/local_decoder.xml"
green ""
