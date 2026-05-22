#!/usr/bin/env bash
# 07o — OpenBao + Keycloak audit decoder + rules.
#
# Installs the manager-side decoder + rules that parse OpenBao audit
# events and Keycloak logger output shipped by the host wazuh-agent's
# openbao / keycloak <localfile> blocks:
#
#   decoder  openbao-keycloak-json.xml   — claims kubelet-wrapped
#            (`F `/`P ` prefixed) JSON pod-log lines so JSON_Decoder
#            parses the OpenBao/Keycloak payload.
#   rules    openbao-keycloak-audit.xml  — 100300-100399:
#            OpenBao audit (100300-100306) + Keycloak logger
#            (100320-100324). See the rule XML header for IDs.
#
# Source-of-truth for both files is this repo:
#   platform/manifests/wazuh/local-decoders/openbao-keycloak-json.xml
#   platform/manifests/wazuh/local-rules/openbao-keycloak-audit.xml
#
# The host wazuh-agent must tail the openbao + keycloak pod log paths;
# the ossec.conf.template already carries those <localfile> blocks
# (deployed by 11-wazuh-host-agent.sh) — this script does NOT modify
# ossec.conf.
#
# Run AFTER 07-wazuh.sh deploys the manager. Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

DECODER_SRC="$PLATFORM_DIR/manifests/wazuh/local-decoders/openbao-keycloak-json.xml"
RULE_SRC="$PLATFORM_DIR/manifests/wazuh/local-rules/openbao-keycloak-audit.xml"

NS=wazuh
MGR_POD=wazuh-manager-0
DECODER_DEST=/var/ossec/etc/decoders/local_decoder_openbao_keycloak.xml
RULE_DEST=/var/ossec/etc/rules/local_rules_openbao_keycloak_audit.xml

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

[ -f "$DECODER_SRC" ] || { red "ERROR: $DECODER_SRC not found"; exit 1; }
[ -f "$RULE_SRC" ]    || { red "ERROR: $RULE_SRC not found"; exit 1; }

# 1. Push decoder to manager
green "==> [1/4] push openbao-keycloak-json decoder to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $DECODER_DEST" < "$DECODER_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $DECODER_DEST
  chmod 0640 $DECODER_DEST
"

# 2. Push rules to manager
green "==> [2/4] push openbao-keycloak-audit rules to manager"
kubectl exec -i -n "$NS" "$MGR_POD" -c wazuh-manager -- \
  bash -c "cat > $RULE_DEST" < "$RULE_SRC"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- bash -c "
  chown wazuh:wazuh $RULE_DEST
  chmod 0640 $RULE_DEST
"

# 3. Validate manager config (decoder + rules together)
green "==> [3/4] validate manager analysisd config"
if ! kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5; then
  red "    analysisd validation failed; investigate before reloading"
  exit 1
fi

# 4. Reload manager so the new decoder + rules take effect
green "==> [4/4] reload manager"
kubectl exec -n "$NS" "$MGR_POD" -c wazuh-manager -- /var/ossec/bin/wazuh-control reload 2>&1 | tail -3

cat <<EOF

✓ OpenBao + Keycloak audit decoder + rules installed.

Rule IDs added:
  100300-100306  OpenBao audit (base, auth/policy error, sys/ + auth/jwt/
                 + transit/keys/ mutations, read-denial, brute-force corr.)
  100320-100324  Keycloak logger (base, WARN, ERROR, FATAL, audit event)

Pre-condition (verify on the host if alerts don't appear):
  - host wazuh-agent ossec.conf tails the openbao + keycloak pod logs
      grep -c 'source">openbao\|source">keycloak' /var/ossec/etc/ossec.conf
  - OpenBao has a file/socket audit device writing to stdout, otherwise
    no OpenBao audit events reach the pod log at all
  - Keycloak audit events (100323) need the realm's jboss-logging event
    listener enabled:
      kcadm update events/config -r <realm> -s eventsListeners='["jboss-logging"]'

Test the decoder + rules with wazuh-logtest:
  kubectl exec -i -n $NS $MGR_POD -c wazuh-manager -- /var/ossec/bin/wazuh-logtest <<'JSON'
  F {"type":"request","auth":{"display_name":"test"},"request":{"operation":"read","path":"sys/health"}}
  JSON
  # expect: rule 100300 (and 100302 for the sys/ match)
EOF
