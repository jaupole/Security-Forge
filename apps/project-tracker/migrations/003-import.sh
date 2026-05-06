#!/usr/bin/env bash
# Phase 10.1.3 — Import live PT data from the local docker-compose
# Postgres into secforge-app-db.project_tracker.* with tenant_id
# backfilled to the AECOM-BD-Jason UUID.
#
# Workflow:
#   1. pg_dump from the local PF docker-compose `db` service (which
#      hosts the `project_tracker` database in volume `proposalforge_pgdata`).
#      Use `--data-only --column-inserts --no-owner --schema=public` so
#      the dump is portable INSERT statements with explicit column lists.
#   2. sed-transform: rewrite `INSERT INTO public.<table>` → `INSERT INTO
#      project_tracker.<table>` and inject the tenant_id column +
#      AECOM-BD-Jason UUID into every VALUES tuple. Per-table rewriting
#      is more robust than a single regex pass — the audit_logs table's
#      JSONB `data` column can contain `VALUES (` substrings inside
#      payloads that would confuse a global regex.
#   3. Mint short-lived `project-tracker-migrate` creds via OpenBao
#      and apply the transformed dump in a single transaction with
#      `SET LOCAL row_security = off` (the migrate role inherits
#      project_tracker_app and so falls under the RLS policies just
#      installed in 002 — bypass the policies for this one-shot import,
#      then they re-engage on every subsequent query).
#
# Pre-conditions:
#   - apply.sh ran successfully (schema + RLS in place)
#   - PF docker-compose `db` running with PT data populated:
#       docker compose -f Proposal\ Forge/docker-compose.yml up -d db
#       docker exec proposalforge-db-1 psql -U proposalforge \
#           -c "CREATE DATABASE project_tracker;"
#       cd Project\ Tracker
#       DATABASE_URL='postgres://proposalforge:proposalforge@localhost:5432/project_tracker' \
#           npx prisma migrate deploy
#       DATABASE_URL='postgres://proposalforge:proposalforge@localhost:5432/project_tracker' \
#           npx prisma db seed
#   - BAO_TOKEN exported with admin-tier capabilities (mints
#     project-tracker-migrate creds)
#
# Cleanup: the lease is auto-revoked on script exit (trap). The
# transformed dump is removed from /tmp; the original dump stays at
# /tmp/pt-data-dump.sql for post-mortem inspection if 004-verify
# reports a mismatch.

set -euo pipefail

: "${TENANT_UUID:?need TENANT_UUID — see apps/project-tracker/TENANT.md}"

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use:\n" >&2
    printf "  export BAO_ADDR=https://bao.secforge.local; export BAO_SKIP_VERIFY=1\n" >&2
    printf "  bao login -method=oidc role=admin -format=json | jq -r .auth.client_token > ~/.bao-token\n" >&2
    printf "  TENANT_UUID=<uuid> BAO_TOKEN=\$(cat ~/.bao-token) bash $(basename "$0")\n" >&2
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

DUMP_FILE=/tmp/pt-data-dump.sql
TRANSFORMED_FILE=/tmp/pt-data-transformed.sql

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── Section 1 — pg_dump from local docker-compose ───────────────────
green "==> pg_dump from local PT (docker-compose) — data only, public schema"
if ! docker exec "$LOCAL_PG_CONTAINER" pg_isready -U "$LOCAL_PG_USER" >/dev/null 2>&1; then
    red "local Postgres ($LOCAL_PG_CONTAINER) not ready. Start it first:"
    red "  cd 'Proposal Forge' && docker compose up -d db"
    exit 1
fi

# `--exclude-table=_prisma_migrations` keeps Prisma's internal migration-
# history table out of the dump. The cluster doesn't track PT's local
# migration history; schema management in the cluster goes through
# apps/project-tracker/migrations/00N-*.sql, not Prisma's _prisma_migrations.
docker exec "$LOCAL_PG_CONTAINER" pg_dump \
    -U "$LOCAL_PG_USER" -d "$LOCAL_PG_DB" \
    --data-only --column-inserts --no-owner --schema=public \
    --exclude-table=_prisma_migrations \
    > "$DUMP_FILE"

DUMP_LINES=$(wc -l < "$DUMP_FILE")
DUMP_INSERTS=$(grep -c '^INSERT INTO ' "$DUMP_FILE" || true)
green "    dump: $DUMP_LINES lines, $DUMP_INSERTS INSERT statements at $DUMP_FILE"

# ─── Section 2 — sed-transform ───────────────────────────────────────
# Five transformations:
#   T1: drop pg_dump 16.13's `\restrict` / `\unrestrict` directives —
#       the cluster's Postgres 16.4 psql doesn't recognize them
#       (`invalid command \restrict`).
#   T2: drop pg_dump's `SET row_security = off;` preamble line.
#       pg_dump emits this assuming the importer is a superuser who
#       can bypass RLS. Our importer is the OpenBao-minted migrate
#       role (non-superuser, no BYPASSRLS), so `row_security = off`
#       trips Postgres into the "query would be affected by row-level
#       security policy" error path. We want RLS engaged with the
#       session's app.tenant_id matching every row's tenant_id —
#       positive RLS pass, not bypass.
#   T3: INSERT INTO public.<table> (col1, ...) →
#       INSERT INTO project_tracker.<table> (tenant_id, col1, ...)
#       Schema rename + new column at the START of the column list.
#   T4: VALUES (X, ...) → VALUES ('<UUID>', X, ...)
#       Inject the UUID literal as the first VALUES tuple element.
#       Anchored to lines that already went through T3 so the transform
#       doesn't touch JSONB payloads inside audit_logs.data that may
#       contain the substring `VALUES (`.
#   T5: SELECT pg_catalog.setval('public.<seq>', ...) →
#       SELECT pg_catalog.setval('project_tracker.<seq>', ...)
#       pg_dump emits setval() calls to preserve BIGSERIAL counters
#       so future inserts don't collide with imported IDs. The cluster
#       has the sequences in project_tracker, not public.
#
# audit_logs has JSONB data — the dump emits each JSONB literal as a
# single-quoted string with internal chars escaped, so embedded
# `VALUES (` inside the JSON string never appears at the start of an
# INSERT statement and won't match the anchored T4 pattern.
#
# The UUID is wrapped in single quotes (SQL string literal). Bash's
# double-quoted string makes `'...'` literal — no `'"'"'` escaping
# voodoo needed. Don't add a layer.
green "==> sed-transform: drop \\restrict + drop row_security=off + schema rename + tenant_id injection + setval retarget"
sed -E \
    -e '/^\\(restrict|unrestrict) /d' \
    -e '/^SET row_security = off;$/d' \
    -e 's/^INSERT INTO public\.([a-z_]+) \(/INSERT INTO project_tracker.\1 (tenant_id, /' \
    -e "/^INSERT INTO project_tracker\./ s/ VALUES \(/ VALUES ('$TENANT_UUID', /" \
    -e "s/setval\\('public\\./setval('project_tracker./g" \
    "$DUMP_FILE" \
    > "$TRANSFORMED_FILE"

TRANSFORMED_INSERTS=$(grep -c '^INSERT INTO project_tracker\.' "$TRANSFORMED_FILE" || true)
if [ "$TRANSFORMED_INSERTS" != "$DUMP_INSERTS" ]; then
    red "transform mismatch: dump had $DUMP_INSERTS INSERT lines, transformed has $TRANSFORMED_INSERTS"
    red "Inspect $DUMP_FILE and $TRANSFORMED_FILE before re-running."
    exit 1
fi
green "    transformed: $TRANSFORMED_INSERTS INSERTs (matches source)"

# Quick visual check on the first few lines (showed as yellow stderr).
yellow "    sample transformed lines:"
grep '^INSERT INTO project_tracker' "$TRANSFORMED_FILE" | head -3 | sed 's/^/    /' >&2

# ─── Section 3 — mint migrate creds + apply ──────────────────────────
green "==> mint database/creds/project-tracker-migrate (15m TTL)"
CREDS_JSON=$(kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao read -format=json database/creds/project-tracker-migrate)
PG_USER=$(echo "$CREDS_JSON" | jq -r '.data.username')
PG_PASS=$(echo "$CREDS_JSON" | jq -r '.data.password')
LEASE_ID=$(echo "$CREDS_JSON" | jq -r '.lease_id')
yellow "    minted username=$PG_USER (lease=$LEASE_ID, ttl=15m)"

# Auto-revoke on exit.
trap 'kubectl exec -n "'"$NS_BAO"'" "'"$BAO_POD"'" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="'"$BAO_TOKEN"'" bao lease revoke "'"$LEASE_ID"'" >/dev/null 2>&1 || true' EXIT

green "==> apply transformed dump (BEGIN; SET LOCAL app.tenant_id; ...; COMMIT;)"
# RLS-aware import strategy:
#
#   The migrate role inherits project_tracker_app and so falls under
#   the RLS policies installed in 002. The naive "bypass" approach
#   (`SET LOCAL row_security = off`) does NOT actually bypass — for
#   a non-superuser without BYPASSRLS, Postgres raises:
#     ERROR: query would be affected by row-level security policy
#   instead of silently filtering. That's a Postgres safety feature.
#   See https://www.postgresql.org/docs/current/sql-createpolicy.html.
#
#   Better path: set `app.tenant_id` to the AECOM-BD-Jason UUID for the
#   import session. Every row in the transformed dump already has that
#   UUID injected by the sed-transform, so the policy's WITH CHECK
#   clause (tenant_id = current_setting('app.tenant_id')::uuid) passes
#   on every INSERT — the rows match the session's tenant. This tests
#   RLS positively (the policy is doing its job by ALLOWING this
#   single-tenant import) rather than circumventing it.
#
#   Phase D (004-verify.sh) then exercises the negative cases:
#   wrong-tenant SET → 0 rows visible; GUC unset → 0 rows visible.
#
#   The transaction is atomic — any error rolls back to a clean schema.
{
    echo "BEGIN;"
    echo "SET LOCAL app.tenant_id = '$TENANT_UUID';"
    cat "$TRANSFORMED_FILE"
    echo "COMMIT;"
} | kubectl exec -i -n "$NS_APP" "$PG_POD" -c postgres -- \
    env PGPASSWORD="$PG_PASS" \
    psql -U "$PG_USER" -h secforge-app-db-rw.app.svc.cluster.local \
         -d "$PG_DB" -v ON_ERROR_STOP=1 >/dev/null

green "    transactional import succeeded"

# Cleanup the transformed file. Keep the raw dump for post-mortem.
rm -f "$TRANSFORMED_FILE"

green ""
green "Data imported. Run 004-verify.sh to confirm row counts + RLS scoping."
green "  bash $(dirname "$0")/004-verify.sh"
