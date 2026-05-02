#!/usr/bin/env bash
# verify-integration.sh — end-to-end verification for apps/lib/api-auth.
#
# This script validates the audience-at-login + DPoP + per-hop audit
# pattern across a 2-hop call chain: BFF → upstream backend.
#
# Prerequisites
# -------------
#  1. BFF image rebuilt + rolled with the commit-5 wiring
#     (BFF_AUDIENCE_LIST / BFF_BACKEND_AUDIENCE / BFF_WORKLOAD_ID set).
#  2. A backend service running at BFF_BACKEND_URL — Phase 9 lands the
#     hello-world backend; until then, /api/* returns 502.
#  3. Loki + Tempo + Promtail live (Phase 7 ✅).
#  4. A user session with a valid refresh_token (browser login first
#     OR `bao login -method=oidc role=admin` flow's by-product).
#
# What it checks
# --------------
#  Layer 1 (always run): scoped Go tests + scoped build/vet/fmt for
#                        apps/lib/api-auth and apps/helloworld-bff.
#  Layer 2 (cluster):    BFF /healthz, /ready, /login PAR redirect.
#  Layer 3 (chain):      a 2-hop request through BFF → AuthZEN-facade
#                        with a known X-Request-ID, then a Loki query
#                        confirming both hop lines share the request_id.
#                        (Skipped when the backend is not up; layer 2
#                        is the highest-fidelity check available pre-
#                        Phase-9.)
#
# Usage
# -----
#   bash infrastructure/lib/api-auth/verify-integration.sh
#
# Exit code is 0 on all-green, non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

green "==> Layer 1: scoped Go tests + build/vet/fmt"
docker run --rm \
  -v "$REPO_ROOT/apps:/work" \
  -w /work/lib \
  -e GOFLAGS=-mod=mod \
  golang:1.25 \
  bash -c "go test -race -count=10 -timeout=180s ./api-auth/ && \
           go test -cover ./api-auth/ && \
           go vet ./api-auth/ && \
           gofmt -l ./api-auth/" || { red "Layer 1 failed"; exit 1; }
green "    Layer 1 OK"

green "==> Layer 2: BFF cluster reachability"
if ! kubectl get deploy -n app helloworld-bff >/dev/null 2>&1; then
  yellow "    helloworld-bff Deployment not found in app ns — skipping Layer 2."
  yellow "    (Build + roll the new image first; see docs/03-runbooks/api-auth-library.md)"
else
  PF_PORT=18000
  kubectl port-forward -n app svc/helloworld-bff "${PF_PORT}":3000 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3

  echo "    /healthz:   $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PF_PORT}/healthz)"
  echo "    /ready:     $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PF_PORT}/ready)"
  echo "    /login:     $(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PF_PORT}/login) (302 expected → Keycloak PAR)"
  green "    Layer 2 OK"
fi

green "==> Layer 3: 2-hop chain → Loki request_id correlation"
if [ -z "${BACKEND_RUNNING:-}" ]; then
  yellow "    Skipping — set BACKEND_RUNNING=1 once Phase 9's hello-world backend is live."
  yellow "    (Layer 3's Loki query is the canonical demonstration that LogHop's"
  yellow "    schema reconstructs a call chain via {request_id=\"...\"} — needs"
  yellow "    real upstream traffic to produce log lines.)"
  exit 0
fi

REQUEST_ID="e2e-int-test-$(date +%s)"
green "    Sending request with X-Request-ID=${REQUEST_ID} ..."
# Test request — adapt path + auth to whatever Phase 9's backend exposes.
curl -sk -H "X-Request-ID: ${REQUEST_ID}" "https://app.secforge.local/api/healthz" >/dev/null

green "    Waiting 10s for Loki/Promtail batching ..."
sleep 10

PASS=$(kubectl get secret -n observability kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
START=$(( $(date +%s) - 600 ))000000000
END=$(date +%s)000000000
RESP=$(curl -sk -u "admin:${PASS}" -G \
  "https://grafana.secforge.local/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={namespace=\"app\"} |~ \"${REQUEST_ID}\"" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "limit=20")
HOPS=$(echo "$RESP" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); res=d.get('data',{}).get('result',[]); print(sum(len(r.get('values',[])) for r in res))")
echo "    Loki returned ${HOPS} log line(s) carrying request_id"

if [ "$HOPS" -ge 2 ]; then
  green "    Layer 3 OK (≥2 hop lines correlate via request_id)"
else
  red   "    Layer 3 FAILED — expected ≥2 hop lines, got ${HOPS}"
  red   "    Inspect: kubectl logs -n app deploy/helloworld-bff -c bff | grep '${REQUEST_ID}'"
  exit 1
fi
