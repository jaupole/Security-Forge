#!/usr/bin/env bash
# SecForge — Wazuh alert-index retention via an OpenSearch ISM policy.
#
# THE PROBLEM
#   Nothing prunes the indexer. wazuh-alerts-4.x-YYYY.MM.DD indices
#   accumulate forever — the wazuh-manager-cleanup CronJob only clears
#   the manager's vd_updater temp dir, not indexer data. On 2026-05-19
#   the operator-backlog #20 livenessProbe bug crash-looped the manager
#   and one day's index ballooned to 10.7M docs / 11.5 GB (the manager
#   re-ingesting logs across 52 restarts) before anyone noticed.
#
# THE FIX
#   An Index State Management (ISM) policy 'wazuh-alerts-retention':
#   a fresh index sits in 'hot', and RETENTION_DAYS after creation the
#   index transitions to 'delete' and is removed. The policy's
#   ism_template auto-attaches it to every NEW index matching
#   wazuh-alerts-* — no per-index action needed going forward.
#
#   Tune retention by editing RETENTION_DAYS below (default 60d).
#
# Idempotent: creates the policy if absent, updates it in place (ISM
# requires if_seq_no/if_primary_term for updates) if present. Re-running
# is safe. Also enrols any already-existing wazuh-alerts-* index.
#
# Uses the ambient kubectl context (root via k3s.yaml, or a user with
# ~/.kube/config). curl runs inside the indexer pod, which already
# trusts localhost:9200's TLS.
#
# Usage (host or workstation with kubectl access to the cluster):
#   bash infrastructure/wazuh/07-alerts-retention-ism.sh

set -euo pipefail

NS=wazuh
POLICY=wazuh-alerts-retention
RETENTION_DAYS=60
INDEX_PATTERN='wazuh-alerts-*'

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

U=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)

idx_get() { kubectl exec    -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }
idx_put() { kubectl exec -i -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }

POLICY_BODY=$(cat <<JSON
{
  "policy": {
    "description": "SecForge: delete wazuh-alerts indices ${RETENTION_DAYS}d after creation",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [
          { "state_name": "delete", "conditions": { "min_index_age": "${RETENTION_DAYS}d" } }
        ]
      },
      {
        "name": "delete",
        "actions": [ { "delete": {} } ],
        "transitions": []
      }
    ],
    "ism_template": [
      { "index_patterns": ["${INDEX_PATTERN}"], "priority": 100 }
    ]
  }
}
JSON
)

EXISTING=$(idx_get "https://localhost:9200/_plugins/_ism/policies/${POLICY}")

if printf '%s' "$EXISTING" | grep -q "\"_id\":\"${POLICY}\""; then
    SEQ=$(printf '%s' "$EXISTING" | sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p')
    PT=$(printf '%s'  "$EXISTING" | sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p')
    green "==> updating existing ISM policy '${POLICY}' (seq_no=${SEQ} primary_term=${PT})"
    RESP=$(printf '%s' "$POLICY_BODY" | idx_put -XPUT -H 'Content-Type: application/json' \
        "https://localhost:9200/_plugins/_ism/policies/${POLICY}?if_seq_no=${SEQ}&if_primary_term=${PT}" \
        --data-binary @-)
else
    green "==> creating ISM policy '${POLICY}'"
    RESP=$(printf '%s' "$POLICY_BODY" | idx_put -XPUT -H 'Content-Type: application/json' \
        "https://localhost:9200/_plugins/_ism/policies/${POLICY}" \
        --data-binary @-)
fi
echo "    indexer: ${RESP}"
printf '%s' "$RESP" | grep -q "\"_id\":\"${POLICY}\"" \
    || { red "policy PUT failed — see response above."; exit 1; }

# Enrol any wazuh-alerts-* index that already exists (ism_template only
# attaches at index-creation time, so anything created before the policy
# existed needs an explicit add). No-op when there are no such indices.
green "==> enrolling existing ${INDEX_PATTERN} indices (if any)"
ADD=$(printf '{"policy_id":"%s"}' "$POLICY" | idx_put -XPOST -H 'Content-Type: application/json' \
    "https://localhost:9200/_plugins/_ism/add/${INDEX_PATTERN}" --data-binary @-)
echo "    indexer: ${ADD}"

green ""
green "ISM policy '${POLICY}' applied — ${INDEX_PATTERN} indices auto-delete"
green "${RETENTION_DAYS} days after creation, and the policy attaches to new"
green "indices automatically (ism_template)."
green ""
