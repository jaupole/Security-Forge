#!/usr/bin/env bash
# 07l — Install custom Wazuh decoder + rules for upstream-image-check.
#
# Ships our `upstream-image-check.sh` syslog output as a distinct alert
# class on the Wazuh dashboard:
#   - Decoder parses image, old/new digests into structured fields
#   - Rule 100401 fires at level 10 with groups
#     `update_required,upstream_image,security_update`
#
# In the dashboard, filter on rule.groups: "update_required" to see
# only "bump this image" alerts, distinct from regular SCA/syslog/etc.
#
# Run AFTER 07-wazuh.sh deploys the manager. Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

DECODER_SRC="$PLATFORM_DIR/manifests/wazuh/local-decoders/upstream-image-check.xml"
RULE_SRC="$PLATFORM_DIR/manifests/wazuh/local-rules/upstream-image-check.xml"

NS=wazuh
MGR_POD=wazuh-manager-0
DECODER_DEST=/var/ossec/etc/decoders/local_decoder_upstream_image.xml
RULE_DEST=/var/ossec/etc/rules/local_rules_upstream_image.xml

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -f "$DECODER_SRC" ] || { echo "ERROR: $DECODER_SRC not found" >&2; exit 1; }
[ -f "$RULE_SRC" ]    || { echo "ERROR: $RULE_SRC not found"    >&2; exit 1; }

# 1. Push decoder
green "==> [1/3] push decoder to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $DECODER_DEST" < "$DECODER_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $DECODER_DEST
  chmod 0640 $DECODER_DEST
"

# 2. Push rule
green "==> [2/3] push rule to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $RULE_DEST" < "$RULE_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $RULE_DEST
  chmod 0640 $RULE_DEST
"

# 3. Validate + reload
green "==> [3/3] validate config + reload manager"
if kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-logtest -t 2>&1 | tail -5; then
  yellow "    config validated"
else
  yellow "    wazuh-logtest -t returned warnings (may be unrelated)"
fi
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -3

cat <<EOF

✓ Custom decoder + rules installed.

Verify by injecting a synthetic log on the host:
  logger -t upstream-image-check -p daemon.warning \\
    "TEST: NEW DIGEST AVAILABLE for ghcr.io/test:latest (was sha256:aaa, now sha256:bbb)"

Then in the Wazuh dashboard, filter on:
  rule.id: 100401
  OR rule.groups: "update_required"

Expected fields on the alert:
  data.image       -> ghcr.io/test:latest
  data.old_digest  -> sha256:aaa
  data.new_digest  -> sha256:bbb
  rule.level       -> 10
  rule.groups      -> [update_required, upstream_image, security_update]
EOF
