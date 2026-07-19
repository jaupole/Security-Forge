#!/usr/bin/env bash
# 07p — Wazuh index retention via OpenSearch ISM policies.
#
# THE PROBLEM
#   Nothing prunes the indexer. wazuh-alerts-4.x-YYYY.MM.DD indices
#   accumulate forever — the wazuh-manager-cleanup CronJob only clears
#   the manager's vd_updater temp dir, not indexer data. On 2026-05-19
#   the operator-backlog #20 livenessProbe bug crash-looped the manager
#   and one day's index ballooned to 10.7M docs / 11.5 GB (the manager
#   re-ingesting logs across 52 restarts) before anyone noticed.
#   2026-07-19: the weekly wazuh-monitoring-* / wazuh-statistics-* indices
#   turned out to be just as unbounded (they merely grow slower). Unbounded
#   index count also feeds the indexer's slab/page-cache working-set creep
#   (see ContainerMemoryNearLimit RCA in values/wazuh.yaml).
#
# THE FIX
#   Index State Management (ISM) policies: a fresh index sits in 'hot',
#   and RETENTION days after creation the index transitions to 'delete'
#   and is removed. Each policy's ism_template auto-attaches it to every
#   NEW index matching its patterns — no per-index action needed going
#   forward.
#
#     wazuh-alerts-retention  60d  wazuh-alerts-*
#     wazuh-ops-retention     90d  wazuh-monitoring-*, wazuh-statistics-*
#
#   wazuh-states-* is deliberately NOT covered — those are current-state
#   inventory indices (one per manager), not time-series; deleting them
#   loses live state.
#
#   Tune retention by editing the apply_retention_policy calls below.
#
# Idempotent: creates each policy if absent, updates it in place (ISM
# requires if_seq_no/if_primary_term for updates) if present. Re-running
# is safe. Also enrols any already-existing matching index (ism_template
# only attaches at index-creation time).
#
# Uses the ambient kubectl context. curl runs inside the indexer pod,
# which already trusts localhost:9200's TLS.
#
# Run AFTER 07-wazuh.sh deploys the indexer. Idempotent.

set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

NS=wazuh

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

U=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret -n "$NS" wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d)

idx_get() { kubectl exec    -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }
idx_put() { kubectl exec -i -n "$NS" wazuh-indexer-0 -c wazuh-indexer -- curl -s -k -u "$U:$P" "$@"; }

# apply_retention_policy <policy-name> <retention-days> <priority> <pattern>[,<pattern>...]
apply_retention_policy() {
  local policy=$1 days=$2 priority=$3 patterns_csv=$4
  local patterns_json
  patterns_json=$(printf '%s' "$patterns_csv" | awk -F, '{
    for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), $i }')

  local body
  body=$(cat <<JSON
{
  "policy": {
    "description": "SecForge: delete ${patterns_csv} indices ${days}d after creation",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [
          { "state_name": "delete", "conditions": { "min_index_age": "${days}d" } }
        ]
      },
      {
        "name": "delete",
        "actions": [ { "delete": {} } ],
        "transitions": []
      }
    ],
    "ism_template": [
      { "index_patterns": [${patterns_json}], "priority": ${priority} }
    ]
  }
}
JSON
)

  local existing resp
  existing=$(idx_get "https://localhost:9200/_plugins/_ism/policies/${policy}")

  if printf '%s' "$existing" | grep -q "\"_id\":\"${policy}\""; then
      local seq pt
      seq=$(printf '%s' "$existing" | sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p')
      pt=$(printf '%s'  "$existing" | sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p')
      green "==> updating existing ISM policy '${policy}' (seq_no=${seq} primary_term=${pt})"
      resp=$(printf '%s' "$body" | idx_put -XPUT -H 'Content-Type: application/json' \
          "https://localhost:9200/_plugins/_ism/policies/${policy}?if_seq_no=${seq}&if_primary_term=${pt}" \
          --data-binary @-)
  else
      green "==> creating ISM policy '${policy}'"
      resp=$(printf '%s' "$body" | idx_put -XPUT -H 'Content-Type: application/json' \
          "https://localhost:9200/_plugins/_ism/policies/${policy}" \
          --data-binary @-)
  fi
  echo "    indexer: ${resp}"
  printf '%s' "$resp" | grep -q "\"_id\":\"${policy}\"" \
      || { red "policy PUT failed — see response above."; exit 1; }

  # Enrol matching indices that already exist (ism_template only attaches at
  # index-creation time). Already-managed indices come back in the response's
  # failed list — harmless. No-op when there are no such indices.
  green "==> enrolling existing ${patterns_csv} indices (if any)"
  local add
  add=$(printf '{"policy_id":"%s"}' "$policy" | idx_put -XPOST -H 'Content-Type: application/json' \
      "https://localhost:9200/_plugins/_ism/add/${patterns_csv}" --data-binary @-)
  echo "    indexer: ${add}"
}

apply_retention_policy wazuh-alerts-retention 60 100 'wazuh-alerts-*'
apply_retention_policy wazuh-ops-retention    90  50 'wazuh-monitoring-*,wazuh-statistics-*'

cat <<'EOF'

✓ ISM retention applied:
    wazuh-alerts-retention  60d  wazuh-alerts-*
    wazuh-ops-retention     90d  wazuh-monitoring-*, wazuh-statistics-*
  Policies auto-attach to new matching indices (ism_template); existing
  indices were enrolled explicitly. wazuh-states-* is intentionally
  unmanaged (current-state, not time-series).
EOF
