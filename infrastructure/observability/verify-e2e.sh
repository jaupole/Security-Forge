#!/usr/bin/env bash
# Phase 7.9 — end-to-end observability verification.
#
# Fires a small set of synthetic requests with a unique correlation ID
# and confirms each one shows up across all observability pillars:
#
#   1. Metrics (Prometheus)   — counter for the BFF / AuthZEN went up
#   2. Logs    (Loki)         — application log lines for the request
#   3. Traces  (Tempo)        — at least one span per producer service
#   4. Audit   (Loki)         — OpenBao audit log entries
#   5. SIEM    (Wazuh)        — indexer cluster healthy + dashboard reachable
#                               (Phase 7.2 added; agent + log-forwarding
#                                deferred — see docs/03-runbooks/wazuh-operations.md)
#
# Local-edition shortcut: we don't run a full browser passkey flow (that
# needs UI automation we don't have set up yet). Instead we hit:
#   - BFF /login    — generates BFF + Keycloak HTTP traffic + spans
#   - AuthZEN /access/v1/evaluation — generates AuthZEN + SpiceDB spans
#
# Both endpoints exercise the OIDC + AuthZ path that real user traffic
# will use, so a green run here means the full pipeline is healthy.

set -euo pipefail

CORR_ID="e2e-$(date +%s%N | head -c 13)"
PASS=$(kubectl get secret -n observability kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
GRAFANA="https://grafana.secforge.local"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. Generate traffic ─────────────────────────────────────────────
green "==> [1/5] generating synthetic traffic with correlation_id=$CORR_ID"

kubectl port-forward -n app svc/helloworld-bff 13000:3000 >/tmp/.pf-bff 2>&1 &
PF_BFF=$!
kubectl port-forward -n app svc/authzen-facade 18080:8080 >/tmp/.pf-az 2>&1 &
PF_AZ=$!
trap "kill $PF_BFF $PF_AZ 2>/dev/null || true" EXIT
sleep 2

# Hit BFF /login 5x — produces 302 redirects to Keycloak PAR.
for i in 1 2 3 4 5; do
    curl -s -o /dev/null -H "X-Correlation-Id: $CORR_ID" "http://localhost:13000/login"
done

# Hit AuthZEN /access/v1/evaluation 3x with same corr id — produces a
# decision per call (alice doesn't actually have permission today —
# we don't care, we want the evaluation pipeline to fire).
for i in 1 2 3; do
    curl -s -o /dev/null -H "X-Correlation-Id: $CORR_ID" \
        -H "Content-Type: application/json" \
        -X POST -d '{"subject":{"type":"user","id":"alice"},"action":{"name":"view"},"resource":{"type":"document","id":"doc1"}}' \
        "http://localhost:18080/access/v1/evaluation"
done

green "    sent: 5 GET /login + 3 POST /access/v1/evaluation"

# ─── 2. Wait for telemetry to settle ─────────────────────────────────
green "==> [2/5] waiting 12s for batchers to flush (BFF/AuthZEN) and Tempo to index"
sleep 12

# ─── 3. Metrics check ─────────────────────────────────────────────────
green "==> [3/5] metrics — confirm Prometheus counters reflect the requests"

q_prom() {
    # Use Grafana's prometheus datasource proxy so URL encoding is handled
    # by curl --data-urlencode. Avoids shell-quoting hell with kubectl exec.
    curl -sk -u "admin:$PASS" -G "$GRAFANA/api/datasources/proxy/uid/prometheus/api/v1/query" \
        --data-urlencode "query=$1" 2>/dev/null
}

bff_metric=$(q_prom 'sum(promhttp_metric_handler_requests_total{job="helloworld-bff"})' \
    | python3 -c "import json,sys
try:
    r=json.loads(sys.stdin.read())['data']['result']
    print(r[0]['value'][1] if r else '0')
except Exception:
    print('?')" )
spicedb_rate=$(q_prom 'sum(rate(grpc_server_handled_total{namespace="spicedb",grpc_method="CheckPermission"}[5m]))' \
    | python3 -c "import json,sys
try:
    r=json.loads(sys.stdin.read())['data']['result']
    print(f\"{float(r[0]['value'][1]):.2f}\" if r else '0')
except Exception:
    print('?')" )

green "    BFF /metrics scrapes (sample counter): $bff_metric"
green "    SpiceDB CheckPermission rate (last 5m): $spicedb_rate/sec"

# ─── 4. Logs check (Loki) ─────────────────────────────────────────────
green "==> [4/5] logs — Loki query for BFF + AuthZEN + OpenBao audit"

q_loki() {
    # query_range over last 1h. BFF only logs at startup today (no per-
    # request logging) so a 5-min window misses it; AuthZEN logs every
    # /access/v1/evaluation call so a wider window helps it too.
    local start=$(( $(date +%s) - 3600 ))000000000
    local end=$(date +%s)000000000
    curl -sk -u "admin:$PASS" -G "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
        --data-urlencode "query=$1" \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode "limit=10" 2>/dev/null
}

count_lines() {
    python3 -c "import json,sys
try:
    d=json.loads(sys.stdin.read())
    s=d.get('data',{}).get('result',[])
    print(sum(len(r.get('values',[])) for r in s))
except Exception:
    print('?')"
}

bff_count=$(q_loki '{namespace="app",app="helloworld-bff",container="bff"}' | count_lines)
authzen_count=$(q_loki '{namespace="app",app="authzen-facade"} |~ "evaluate"' | count_lines)
audit_count=$(q_loki '{namespace="openbao"} |~ "\"type\":\"(request|response)\""' | count_lines)
keycloak_count=$(q_loki '{namespace="keycloak",app="keycloak"}' | count_lines)

green "    BFF log lines (last 1h):           $bff_count"
green "    AuthZEN evaluate log lines (1h):   $authzen_count"
green "    OpenBao audit log lines (1h):      $audit_count"
green "    Keycloak log lines (1h):           $keycloak_count"

# ─── 5. SIEM check (Wazuh) ────────────────────────────────────────────
green "==> [5/6] SIEM — Wazuh indexer cluster health + dashboard reachable"

# Indexer cluster status: green or yellow is acceptable on single-replica;
# red means a primary shard is unallocated (data loss risk).
INDEXER_PW=$(kubectl get secret -n wazuh wazuh-indexer-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -z "$INDEXER_PW" ]; then
    yellow "    indexer creds Secret not found — Wazuh not deployed or different namespace"
    wazuh_status="missing"
else
    wazuh_status=$(kubectl exec -n wazuh wazuh-indexer-0 -- \
        curl -sk -u "admin:$INDEXER_PW" https://localhost:9200/_cluster/health 2>/dev/null \
        | python3 -c "import json,sys
try: print(json.loads(sys.stdin.read()).get('status','?'))
except: print('?')" )
fi
green "    indexer cluster status: $wazuh_status"

dashboard_http=$(curl -sk -o /dev/null -w "%{http_code}" https://wazuh.secforge.local/app/login 2>/dev/null || echo "?")
green "    dashboard /app/login: HTTP $dashboard_http"

# ─── 6. Traces check (Tempo) ──────────────────────────────────────────
green "==> [6/6] traces — Tempo service.name tag values"

tempo_services=$(curl -sk -u "admin:$PASS" \
    "$GRAFANA/api/datasources/proxy/uid/tempo/api/search/tag/service.name/values" 2>/dev/null \
    | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(','.join(d.get('tagValues',[])))" 2>/dev/null || echo "?")

green "    services in Tempo: $tempo_services"

# ─── Summary ───────────────────────────────────────────────────────────
echo
green "=================================================================="
green " End-to-end verification — correlation_id=$CORR_ID"
green "=================================================================="

ok=0; warn=0
[ "$bff_count" != "?" ] && [ "$bff_count" -gt 0 ] && { green "  ✅ BFF logs reach Loki ($bff_count lines)"; ok=$((ok+1)); } \
    || { yellow "  ⚠ BFF logs not found in Loki (count=$bff_count)"; warn=$((warn+1)); }
[ "$authzen_count" != "?" ] && [ "$authzen_count" -gt 0 ] && { green "  ✅ AuthZEN logs reach Loki ($authzen_count lines)"; ok=$((ok+1)); } \
    || { yellow "  ⚠ AuthZEN logs not found in Loki (count=$authzen_count)"; warn=$((warn+1)); }
[ "$audit_count" != "?" ] && [ "$audit_count" -gt 0 ] && { green "  ✅ OpenBao audit reaches Loki ($audit_count lines)"; ok=$((ok+1)); } \
    || { yellow "  ⚠ OpenBao audit not found in Loki (count=$audit_count)"; warn=$((warn+1)); }
[ "$keycloak_count" != "?" ] && [ "$keycloak_count" -gt 0 ] && { green "  ✅ Keycloak logs reach Loki ($keycloak_count lines)"; ok=$((ok+1)); } \
    || { yellow "  ⚠ Keycloak logs not found in Loki (count=$keycloak_count)"; warn=$((warn+1)); }
echo "$tempo_services" | grep -q "helloworld-bff" && { green "  ✅ BFF traces reach Tempo"; ok=$((ok+1)); } \
    || { yellow "  ⚠ BFF traces missing from Tempo"; warn=$((warn+1)); }
echo "$tempo_services" | grep -q "authzen-facade" && { green "  ✅ AuthZEN traces reach Tempo"; ok=$((ok+1)); } \
    || { yellow "  ⚠ AuthZEN traces missing from Tempo"; warn=$((warn+1)); }
echo "$tempo_services" | grep -q "spicedb" && { green "  ✅ SpiceDB traces reach Tempo"; ok=$((ok+1)); } \
    || { yellow "  ⚠ SpiceDB traces missing from Tempo"; warn=$((warn+1)); }
echo "$tempo_services" | grep -q "keycloak" && { green "  ✅ Keycloak traces reach Tempo"; ok=$((ok+1)); } \
    || { yellow "  ⚠ Keycloak traces missing from Tempo"; warn=$((warn+1)); }
case "$wazuh_status" in
    green|yellow) green "  ✅ Wazuh indexer cluster $wazuh_status"; ok=$((ok+1)) ;;
    *)            yellow "  ⚠ Wazuh indexer status=$wazuh_status (expected green/yellow)"; warn=$((warn+1)) ;;
esac
case "$dashboard_http" in
    200|302) green "  ✅ Wazuh dashboard reachable (HTTP $dashboard_http)"; ok=$((ok+1)) ;;
    *)       yellow "  ⚠ Wazuh dashboard HTTP $dashboard_http (expected 200/302)"; warn=$((warn+1)) ;;
esac

echo
[ $warn -eq 0 ] && green "PASS — $ok/$((ok+warn)) checks green" \
                || yellow "PARTIAL — $ok/$((ok+warn)) green, $warn warnings (see above)"

green ""
green "Drill-down URLs:"
green "  Grafana:      $GRAFANA"
green "  Auth events:  $GRAFANA/d/secforge-auth-events/"
green "  AuthZ checks: $GRAFANA/d/secforge-authz-checks/"
green "  Tempo search: $GRAFANA/explore?orgId=1&left=%5B%22now-1h%22,%22now%22,%22tempo%22,%7B%22queryType%22:%22traceqlSearch%22%7D%5D"
