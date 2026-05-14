#!/usr/bin/env bash
# SecForge — patch the Wazuh alerts ingest pipeline so k3s API-server audit
# events stop being rejected by the indexer.
#
# THE BUG
#   The host wazuh-agent tails /var/log/k3s-audit.log. RequestResponse-level
#   audit events (Secrets / ConfigMaps / RBAC, per
#   platform/host/k3s/audit-policy.yaml) embed a full Kubernetes object
#   body, and every object's metadata.managedFields.fieldsV1 uses a literal
#   "." as a map key (Server-Side Apply field tracking). When the
#   filebeat-7.10.2-wazuh-alerts-pipeline expands the alert JSON, that "."
#   becomes a field name and OpenSearch rejects the whole document:
#       mapper_parsing_exception: field name cannot contain only the
#       character [.]
#   Result: every RequestResponse audit event (~75% of audit volume by
#   line count) is silently dropped — never indexed, invisible in the
#   dashboard.
#
#   Note: switching the agent's <log_format> from json to syslog does NOT
#   fix this. The manager's built-in `json` decoder re-parses the raw line
#   and re-explodes it, so alerts.json still carries the exploded `data`.
#   The fix has to be downstream of analysisd — here, in the pipeline.
#
# THE FIX
#   Insert a `remove` processor right after the JSON-expansion processor.
#   It drops data.requestObject and data.responseObject for k3s-audit
#   events only (scoped on ctx.location == /var/log/k3s-audit.log). Those
#   two sub-trees are the ONLY carriers of the "." keys, and dropping them
#   also stops the k8s-object-body mapping explosion. Everything else is
#   kept: the structured audit fields (verb, user, objectRef,
#   responseStatus, annotations) AND the complete raw event in full_log.
#
#   filebeat does not overwrite an existing pipeline on restart
#   (filebeat.overwrite_pipelines defaults to false), so this edit persists
#   across manager-pod restarts. Re-run it after a filebeat MAJOR/MINOR
#   upgrade — the pipeline name carries the version (…-7.10.2-…).
#
# Idempotent: keyed on the processor `tag`; re-running once applied is a
# no-op.
#
# Usage (host or workstation with kubectl access to the cluster):
#   bash infrastructure/wazuh/06-ingest-pipeline-patch.sh

set -euo pipefail

NS=wazuh
PIPELINE=filebeat-7.10.2-wazuh-alerts-pipeline
TAG=secforge-drop-k8s-audit-objects
: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { red "jq is required on the machine running this script."; exit 1; }

U=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)

# curl runs inside the indexer pod — it already trusts localhost:9200's TLS.
idx_get() { kubectl exec    -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }
idx_put() { kubectl exec -i -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

green "==> fetching ingest pipeline: $PIPELINE"
idx_get "https://localhost:9200/_ingest/pipeline/$PIPELINE" > "$TMP/pipeline.json"

if ! jq -e --arg p "$PIPELINE" '.[$p].processors | type == "array"' "$TMP/pipeline.json" >/dev/null 2>&1; then
    red "could not read pipeline '$PIPELINE'. Indexer response:"
    cat "$TMP/pipeline.json" >&2
    exit 1
fi

if jq -e --arg t "$TAG" 'any(.. | objects; .tag? == $t)' "$TMP/pipeline.json" >/dev/null 2>&1; then
    green "already patched (processor tag '$TAG' present) — nothing to do."
    exit 0
fi

green "==> inserting 'remove' processor after the JSON-expansion processor"
jq --arg p "$PIPELINE" --arg t "$TAG" '
  .[$p]
  | .processors |= (
      [ .[0] ]
      + [ { "remove": {
              "tag": $t,
              "field": [ "data.requestObject", "data.responseObject" ],
              "if": "ctx.location instanceof String && ctx.location == \"/var/log/k3s-audit.log\"",
              "ignore_missing": true,
              "ignore_failure": true
          } } ]
      + .[1:]
    )
' "$TMP/pipeline.json" > "$TMP/pipeline-new.json"

# Sanity: the JSON-expansion processor must still be first, and our
# processor must land at index 1.
jq -e '.processors[0].json and (.processors[1].remove.tag == "'"$TAG"'")' \
    "$TMP/pipeline-new.json" >/dev/null || { red "transform produced an unexpected shape — aborting, pipeline untouched."; exit 1; }

green "==> PUT $PIPELINE"
RESP=$(idx_put -XPUT -H 'Content-Type: application/json' \
        "https://localhost:9200/_ingest/pipeline/$PIPELINE" \
        --data-binary @- < "$TMP/pipeline-new.json")
echo "    indexer: $RESP"
echo "$RESP" | grep -q '"acknowledged":true' || { red "PUT not acknowledged — check the response above."; exit 1; }

green ""
green "Pipeline patched. k3s-audit RequestResponse events will now index"
green "(data.requestObject / data.responseObject stripped; full_log retained)."
green ""
green "Verify (give filebeat ~1 min to ship fresh events):"
green "  kubectl logs -n $NS wazuh-manager-0 -c wazuh-manager --since=3m | grep -c 'Cannot index event'   # expect 0"
green ""
