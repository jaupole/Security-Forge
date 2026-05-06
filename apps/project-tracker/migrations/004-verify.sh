#!/usr/bin/env bash
# Phase 10.1.3 — Verify the data import + RLS scoping.
#
# Two checks:
#   1. Row-count parity per table: count(public.<table>) on the local
#      docker-compose Postgres == count(project_tracker.<table>) on
#      the cluster secforge-app-db. Any mismatch → exit non-zero.
#   2. RLS scoping: with row_security ON (default), confirm that
#      a. wrong tenant_id GUC → 0 rows visible
#      b. AECOM tenant_id GUC → all rows visible (= source row count)
#      c. GUC unset → 0 rows visible (fail-closed when middleware skips)
#
# Run as the OpenBao-minted runtime role
# (project-tracker-readwrite) — that's the role the actual backend
# will use, so the verification matches production semantics.
#
# Pre-conditions:
#   - apply.sh + 003-import.sh ran successfully
#   - PF docker-compose `db` still running (we re-query it for row counts)
#   - BAO_TOKEN exported
#
# Exits 0 on success with a clean parity table; 1 on any failure.

set -euo pipefail

: "${TENANT_UUID:?need TENANT_UUID — see apps/project-tracker/TENANT.md}"

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set — see apply.sh for the OIDC login flow.\n" >&2
    exit 1
fi

NS_BAO=openbao
BAO_POD=openbao-0
NS_APP=app
PG_POD=secforge-app-db-1
PG_DB=secforge_app

LOCAL_PG_CONTAINER=proposalforge-db-1
LOCAL_PG_USER=proposalforge
LOCAL_PG_DB=project_tracker

# 14 PT tables in dependency order (parents before children for any
# operations that care). Order doesn't matter for parity counting.
TABLES=(
    people
    projects
    project_budget_lines
    tasks
    pursuits
    comms_log
    opp_watch_tracks
    opp_watch_queries
    opp_watch_results
    bl_requests
    audit_logs
    bl_request_contacts
    bl_submissions
    bl_submission_lines
)

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── Section 1 — mint runtime creds ───────────────────────────────────
green "==> mint database/creds/project-tracker-readwrite (1h TTL)"
CREDS_JSON=$(kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao read -format=json database/creds/project-tracker-readwrite)
PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
LEASE_ID=$(echo "$CREDS_JSON" | jq -r '.lease_id')
yellow "    minted username=$PG_USER (lease=$LEASE_ID, ttl=1h)"
trap 'kubectl exec -n "'"$NS_BAO"'" "'"$BAO_POD"'" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="'"$BAO_TOKEN"'" bao lease revoke "'"$LEASE_ID"'" >/dev/null 2>&1 || true' EXIT

# psql_runtime: connects to cluster as the runtime role, sets
# app.tenant_id to the AECOM UUID by default. RLS is engaged.
psql_runtime() {
    kubectl exec -i -n "$NS_APP" "$PG_POD" -c postgres -- \
        env PGPASSWORD="$PG_PASS" \
        psql -U "$PG_USER" -h secforge-app-db-rw.app.svc.cluster.local \
             -d "$PG_DB" -v ON_ERROR_STOP=1 -tA
}

count_local() {
    docker exec "$LOCAL_PG_CONTAINER" psql -U "$LOCAL_PG_USER" -d "$LOCAL_PG_DB" \
        -tA -c "SELECT count(*) FROM public.$1;" 2>/dev/null | tr -d ' \r\n'
}

count_cluster() {
    # Use BEGIN/SET LOCAL to ensure app.tenant_id is set for THIS session;
    # otherwise RLS filters everything to 0.
    # Filter psql output for digit-only lines — `tail -1` would pick up
    # psql's `COMMIT` status line otherwise.
    psql_runtime <<EOF | grep -E '^[0-9]+$' | head -1 | tr -d ' \r\n'
BEGIN;
SET LOCAL app.tenant_id = '$TENANT_UUID';
SELECT count(*) FROM project_tracker.$1;
COMMIT;
EOF
}

# ─── Section 2 — row-count parity ────────────────────────────────────
green "==> row-count parity (local public.* ⇄ cluster project_tracker.*)"
printf "    %-26s %10s %10s %s\n" "TABLE" "LOCAL" "CLUSTER" "STATUS"
printf "    %-26s %10s %10s %s\n" "─────" "─────" "───────" "──────"

PARITY_FAIL=0
TOTAL_LOCAL=0
TOTAL_CLUSTER=0
for t in "${TABLES[@]}"; do
    LOCAL=$(count_local "$t")
    CLUSTER=$(count_cluster "$t")
    : "${LOCAL:=0}"
    : "${CLUSTER:=0}"
    TOTAL_LOCAL=$((TOTAL_LOCAL + LOCAL))
    TOTAL_CLUSTER=$((TOTAL_CLUSTER + CLUSTER))
    if [ "$LOCAL" = "$CLUSTER" ]; then
        printf "    %-26s %10s %10s %s\n" "$t" "$LOCAL" "$CLUSTER" "✓"
    else
        printf "    %-26s %10s %10s %s\n" "$t" "$LOCAL" "$CLUSTER" "✗ MISMATCH"
        PARITY_FAIL=1
    fi
done
printf "    %-26s %10s %10s\n" "TOTAL" "$TOTAL_LOCAL" "$TOTAL_CLUSTER"

if [ "$PARITY_FAIL" = "1" ]; then
    red ""
    red "PARITY FAILED — investigate /tmp/pt-data-dump.sql for the affected table(s)."
    red "Most likely cause: sed-transform mismatch on a table whose data shape"
    red "is unusual (e.g., audit_logs JSONB column with embedded VALUES (...))."
    exit 1
fi
green "    parity OK across all 14 tables ($TOTAL_LOCAL rows total)"

# ─── Section 3 — RLS scoping ─────────────────────────────────────────
green "==> RLS scoping (3 assertions on project_tracker.projects)"

# Use projects as the test table — it has 3 rows in this dataset.
EXPECTED=$(count_local "projects")

# 3a — wrong tenant UUID → expect 0
WRONG_UUID="00000000-0000-0000-0000-000000000000"
WRONG_COUNT=$(psql_runtime <<EOF | grep -E '^[0-9]+$' | head -1 | tr -d ' \r\n'
BEGIN;
SET LOCAL app.tenant_id = '$WRONG_UUID';
SELECT count(*) FROM project_tracker.projects;
COMMIT;
EOF
)
if [ "$WRONG_COUNT" != "0" ]; then
    red "    ✗ wrong-tenant UUID returned $WRONG_COUNT rows (expected 0)"
    exit 1
fi
green "    ✓ wrong tenant UUID → 0 rows (RLS filters all rows out)"

# 3b — AECOM UUID → expect EXPECTED
RIGHT_COUNT=$(psql_runtime <<EOF | grep -E '^[0-9]+$' | head -1 | tr -d ' \r\n'
BEGIN;
SET LOCAL app.tenant_id = '$TENANT_UUID';
SELECT count(*) FROM project_tracker.projects;
COMMIT;
EOF
)
if [ "$RIGHT_COUNT" != "$EXPECTED" ]; then
    red "    ✗ AECOM UUID returned $RIGHT_COUNT rows (expected $EXPECTED)"
    exit 1
fi
green "    ✓ AECOM UUID → $RIGHT_COUNT rows (matches source)"

# 3c — GUC unset → expect 0 (fail-closed)
UNSET_COUNT=$(psql_runtime <<'EOF' | grep -E '^[0-9]+$' | head -1 | tr -d ' \r\n'
SELECT count(*) FROM project_tracker.projects;
EOF
)
if [ "$UNSET_COUNT" != "0" ]; then
    red "    ✗ GUC unset returned $UNSET_COUNT rows (expected 0 — fail-closed)"
    exit 1
fi
green "    ✓ GUC unset → 0 rows (fail-closed when middleware forgets to set tenant_id)"

# ─── Done ────────────────────────────────────────────────────────────
green ""
green "Phase 10.1.3 verification PASSED."
green "  rows imported:           $TOTAL_LOCAL across 14 tables"
green "  RLS positive case:       $RIGHT_COUNT rows for AECOM UUID"
green "  RLS negative cases:      0 rows for wrong UUID + 0 rows for unset GUC"
green ""
green "Cluster is ready for Phase 10.1.4 (BFF-injected identity wiring)."
