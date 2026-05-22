#!/usr/bin/env bash
# 07n — k3s API audit decoder (manager-side claim to suppress auto-JSON).
#
# Companion to the k3s-audit <localfile> block in the host wazuh-agent's
# ossec.conf. That block ships /var/log/k3s-audit.log as syslog with the
# program tag "k3s-audit". This script installs the manager-side decoder
# that matches that program tag and CLAIMS the message — preventing the
# built-in JSON_Decoder from auto-firing on the JSON-starting body and
# producing fields with a literal "." that OpenSearch rejects with
# mapper_parsing_exception.
#
# Rationale (kept short here; full story in the decoder XML header):
#   - k3s audit log is JSON-Lines starting with '{'
#   - Without a claiming decoder, analysisd auto-runs JSON_Decoder
#   - RequestResponse audit events contain SSA fieldsV1 with literal "."
#     as an object key → flattened to a field named "." → indexer drops
#     the entire alert with mapper_parsing_exception
#   - This decoder is intentionally a no-op (no regex, no order) — it
#     exists ONLY to short-circuit the auto-JSON path
#
# Run AFTER 07-wazuh.sh deploys the manager. Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

DECODER_SRC="$PLATFORM_DIR/manifests/wazuh/local-decoders/k3s-audit.xml"

NS=wazuh
MGR_POD=wazuh-manager-0
DECODER_DEST=/var/ossec/etc/decoders/local_decoder_k3s_audit.xml

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ -f "$DECODER_SRC" ] || { red "ERROR: $DECODER_SRC not found"; exit 1; }

# 1. Push decoder to manager
green "==> [1/3] push k3s-audit decoder to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $DECODER_DEST" < "$DECODER_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $DECODER_DEST
  chmod 0640 $DECODER_DEST
"

# 2. Validate manager config
green "==> [2/3] validate manager analysisd config"
if ! kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5; then
  red "    analysisd validation failed; investigate before reloading"
  exit 1
fi

# 3. Reload manager so new decoder takes effect
green "==> [3/3] reload manager"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -3

cat <<EOF

✓ k3s-audit claim decoder installed.

To take full effect, the host wazuh-agent's ossec.conf must include
<out_format>\$(timestamp) \$(hostname) k3s-audit: \$(log)</out_format>
inside the /var/log/k3s-audit.log <localfile> block. The template at
platform/manifests/wazuh-host-agent/ossec.conf.template already has it;
re-run 11-wazuh-host-agent.sh on the host (or edit the live ossec.conf
and restart wazuh-agent) if the live config still lacks the out_format.

Verify with:
  kubectl -n $NS logs $MGR_POD --since=5m | \\
    grep -c "mapper_parsing_exception\\|field name cannot contain only"
  # should be 0 once both ends are in place
EOF
