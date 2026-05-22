#!/usr/bin/env bash
# 14 — Trivy → Wazuh integration.
#
# Wires Trivy Operator CVE findings into the Wazuh SIEM so HIGH/CRITICAL
# vulnerabilities appear as Wazuh alerts (levels 9 and 13) with CVE ID,
# image, package, fix version, and MITRE T1190 tagging.
#
# How it works:
#   1. CronJob in trivy-system reads VulnerabilityReport CRDs every 6h and
#      writes flat NDJSON to /var/log/trivy-wazuh/findings-*.jsonl (hostPath).
#      The CronJob touches the empty file first, waits 90s (> logcollector
#      reload_interval=64) so the agent discovers it at offset=0, then writes.
#   2. Wazuh agent DaemonSet mounts that hostPath; localfile block (syslog
#      format) ships each new file to the Wazuh manager.  Each line is prefixed
#      with a traditional syslog timestamp so the syslog predecoder extracts
#      program_name=trivy-cve.  RFC3339+Z timestamps are NOT recognised.
#   3. Custom decoder + rules on the manager parse + alert.
#      Decoder lives in local_decoder.xml (PVC-backed):
#        trivy       — parent, matches program_name=trivy-cve
#        trivy-json  — child, uses JSON_Decoder plugin for automatic field
#                      extraction.  JSON_Decoder places fields at ROOT level
#                      (not data.*).  Rule <field> and $(var) references must
#                      use the plain field name, e.g. severity not data.severity.
#
# IMPORTANT — Wazuh 4.14.4 SIGHUP limitation:
#   kill -HUP wazuh-analysisd reloads rules but NOT custom decoders from
#   etc/decoders/.  After any decoder change, a full pod restart is required:
#     kubectl delete pod -n wazuh wazuh-manager-0
#   wazuh-logtest always reads decoders fresh; use it to verify syntax before
#   restarting.
#
# /var/ossec/etc is on the manager's PVC so decoders/rules survive pod restarts.
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests"
NS_TRIVY=trivy-system
NS_WAZUH=wazuh
MGR_POD=wazuh-manager-0

# ─── 1. CronJob RBAC + CronJob ─────────────────────────────────────────────
echo ">>> Applying Trivy-Wazuh RBAC + CronJob"
kubectl apply -f "$M/trivy-system/07-trivy-wazuh-rbac.yaml"
kubectl apply -f "$M/trivy-system/08-trivy-wazuh-cronjob.yaml"

# ─── 2. Wazuh agent: ConfigMap + DaemonSet ─────────────────────────────────
echo ">>> Patching Wazuh agent ConfigMap (trivy localfile block)"
kubectl apply -f "$M/wazuh-agent/03-configmap.yaml"

echo ">>> Patching Wazuh agent DaemonSet (trivy-wazuh-logs hostPath mount)"
kubectl apply -f "$M/wazuh-agent/04-daemonset.yaml"
kubectl -n wazuh-agent rollout restart daemonset/wazuh-agent
kubectl -n wazuh-agent rollout status daemonset/wazuh-agent --timeout=120s

# ─── 3. Wazuh manager: decoder ─────────────────────────────────────────────
# The trivy decoders live in local_decoder.xml (appended below).
# trivy.xml is kept as a placeholder to avoid breaking anything if it already
# exists on the PVC.
echo ">>> Ensuring trivy.xml placeholder exists (avoids name collision)"
kubectl -n "$NS_WAZUH" get pod "$MGR_POD" > /dev/null || {
  echo "ERROR: $MGR_POD not running" >&2; exit 1
}

kubectl exec -n "$NS_WAZUH" "$MGR_POD" -- /bin/bash -c \
  'mkdir -p /var/ossec/etc/decoders && cat > /var/ossec/etc/decoders/trivy.xml' << 'PLACEHOLDER_EOF'
<!-- Trivy decoders live in local_decoder.xml.
     This file is a placeholder so re-running 14-trivy-wazuh.sh does not
     accidentally register a duplicate decoder name. -->
<decoder name="trivy-placeholder">
  <program_name>trivy-placeholder-unused</program_name>
</decoder>
PLACEHOLDER_EOF

echo ">>> Appending Trivy decoders to local_decoder.xml"
# Strategy: read the existing file, strip any previous trivy decoder block,
# then re-append the current version. This keeps the script idempotent.
kubectl exec -n "$NS_WAZUH" "$MGR_POD" -- /bin/bash -c '
  FILE=/var/ossec/etc/decoders/local_decoder.xml
  # Remove everything from the trivy block sentinel to the closing tag (idempotent).
  if grep -q "<!-- BEGIN trivy -->" "$FILE" 2>/dev/null; then
    sed -i "/<!-- BEGIN trivy -->/,/<!-- END trivy -->/d" "$FILE"
  fi
' 2>/dev/null || true

kubectl exec -n "$NS_WAZUH" "$MGR_POD" -- /bin/bash -c \
  'cat >> /var/ossec/etc/decoders/local_decoder.xml' << 'DECODER_EOF'

<!-- BEGIN trivy -->
<!-- Trivy Operator CVE findings decoder.
     CronJob prefixes each JSON line with a traditional syslog timestamp so
     the syslog predecoder extracts program_name=trivy-cve.  RFC3339+Z format
     is NOT recognised by the Wazuh 4.14.4 syslog predecoder.

     After editing this file, SIGHUP to wazuh-analysisd is NOT sufficient —
     it only reloads rules, not custom decoders.  Restart the pod:
       kubectl delete pod -n wazuh wazuh-manager-0

     JSON_Decoder extracts all JSON fields at ROOT level (not data.*).
     Rules must use <field name="severity"> not <field name="data.severity">
     and $(severity) not $(data.severity) in descriptions. -->

<!-- Parent: match program_name extracted by syslog predecoder -->
<decoder name="trivy">
  <program_name>trivy-cve</program_name>
</decoder>

<!-- Child: JSON_Decoder auto-extracts all fields at root level -->
<decoder name="trivy-json">
  <parent>trivy</parent>
  <use_own_name>yes</use_own_name>
  <prematch>{</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
<!-- END trivy -->
DECODER_EOF

# ─── 4. Wazuh manager: rules ───────────────────────────────────────────────
echo ">>> Pushing Trivy rules to manager pod (PVC-backed /var/ossec/etc/rules/)"
kubectl exec -n "$NS_WAZUH" "$MGR_POD" -- /bin/bash -c \
  'mkdir -p /var/ossec/etc/rules && cat > /var/ossec/etc/rules/trivy_rules.xml' << 'RULES_EOF'
<!-- Trivy Operator CVE alert rules.
     IDs 100200-100210 (Trivy range).

     Fields decoded by JSON_Decoder (from trivy-json decoder) are available
     at ROOT level — no data.* prefix.  Use $(severity), $(cve_id), etc.
     in descriptions and <field name="severity"> etc. in conditions.

     Wazuh OS_Regex notes:
       .   = literal dot  (NOT wildcard)
       \.  = any character
       \w  = word character
       Use | for alternation in <field> values; parentheses cause syntax error 5107. -->

<group name="trivy,vulnerability,">

  <!-- Base rule: any Trivy finding (CronJob only writes HIGH/CRITICAL) -->
  <rule id="100200" level="5">
    <decoded_as>trivy</decoded_as>
    <description>Trivy: $(severity) CVE $(cve_id) in $(namespace)/$(resource): $(title)</description>
    <group>trivy,cve,</group>
  </rule>

  <!-- HIGH CVE -->
  <rule id="100201" level="9">
    <if_sid>100200</if_sid>
    <field name="severity">^HIGH$</field>
    <description>Trivy: HIGH CVE $(cve_id) in $(image) pkg=$(pkg_name) $(installed_version) fix=$(fixed_version)</description>
    <group>trivy,cve_high,</group>
  </rule>

  <!-- CRITICAL CVE -->
  <rule id="100202" level="13">
    <if_sid>100200</if_sid>
    <field name="severity">^CRITICAL$</field>
    <description>Trivy: CRITICAL CVE $(cve_id) in $(image) pkg=$(pkg_name) $(installed_version) fix=$(fixed_version)</description>
    <group>trivy,cve_critical,</group>
    <mitre>
      <id>T1190</id>
    </mitre>
  </rule>

  <!-- CRITICAL CVE in a public-facing namespace — highest priority.
       NOTE: use | alternation directly; (group) syntax causes error 5107. -->
  <rule id="100203" level="15">
    <if_sid>100202</if_sid>
    <field name="namespace">^keycloak$|^ingress-nginx$</field>
    <description>Trivy: CRITICAL CVE $(cve_id) in PUBLIC namespace $(namespace) - immediate remediation required</description>
    <group>trivy,cve_critical,public_facing,</group>
    <mitre>
      <id>T1190</id>
    </mitre>
  </rule>

</group>
RULES_EOF

# ─── 5. Reload Wazuh analysisd ruleset ─────────────────────────────────────
# SIGHUP reloads rules only.  Custom decoder changes require a full pod restart.
# If this is a first-time install (decoder didn't exist before), restart now.
echo ">>> Reloading Wazuh analysisd ruleset (rules only)"
kubectl exec -n "$NS_WAZUH" "$MGR_POD" -- /bin/bash -c \
  'kill -HUP $(pgrep -x wazuh-analysisd) && echo "ruleset reloaded"'

echo ""
echo "NOTE: If you changed the decoder (trivy/trivy-json in local_decoder.xml),"
echo "      SIGHUP does NOT reload custom decoders in Wazuh 4.14.4."
echo "      Restart the manager pod to pick up decoder changes:"
echo "        kubectl delete pod -n $NS_WAZUH $MGR_POD"
echo ""

# ─── 6. Trigger an immediate first run ─────────────────────────────────────
echo ">>> Triggering immediate first scan (Job from CronJob)"
kubectl create job -n "$NS_TRIVY" \
  trivy-wazuh-initial \
  --from=cronjob/trivy-wazuh-reporter 2>/dev/null || true

echo ">>> Waiting for initial scan Job to complete (max 5m — includes 90s sleep)"
kubectl wait -n "$NS_TRIVY" job/trivy-wazuh-initial \
  --for=condition=Complete --timeout=300s 2>/dev/null \
  || echo "    (initial job still running — check: kubectl logs -n $NS_TRIVY job/trivy-wazuh-initial)"

cat <<EOF

✓ Trivy → Wazuh integration deployed.

  CronJob:    trivy-wazuh-reporter in $NS_TRIVY (every 6h)
  Findings:   /var/log/trivy-wazuh/findings-*.jsonl on the host
  Decoder:    /var/ossec/etc/decoders/local_decoder.xml   (PVC-backed, survives restarts)
              Parent:  trivy        — matches program_name=trivy-cve (syslog predecoder)
              Child:   trivy-json   — JSON_Decoder plugin, fields at root level
  Rules:      /var/ossec/etc/rules/trivy_rules.xml (PVC-backed, survives restarts)

  Rule levels:
    100200  level  5 — any Trivy finding (base)
    100201  level  9 — HIGH CVE
    100202  level 13 — CRITICAL CVE (MITRE T1190)
    100203  level 15 — CRITICAL CVE in keycloak or ingress-nginx

  In Wazuh dashboard:
    Security Events → filter rule.id:[100200 TO 100203]
    or: data.source:trivy

  In alerts.json (direct):
    kubectl exec -n $NS_WAZUH $MGR_POD -- \\
      grep '"id":"100200\|100201\|100202\|100203"' /var/ossec/logs/alerts/alerts.json | tail -5

  Check initial findings landed:
    kubectl logs -n $NS_TRIVY job/trivy-wazuh-initial

  Decoder troubleshooting:
    kubectl exec -n $NS_WAZUH $MGR_POD -- /var/ossec/bin/wazuh-logtest
    # paste: May  9 00:36:09 k3s-node trivy-cve: {"source":"trivy","severity":"CRITICAL",...}
    # Note: wazuh-logtest reads files fresh; live daemon requires pod restart after decoder edits.

  Restart manager after any decoder edit:
    kubectl delete pod -n $NS_WAZUH $MGR_POD
EOF
