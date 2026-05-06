#!/usr/bin/env bash
# Phase 10.1.3 — Apply project_tracker schema + RLS to secforge-app-db.
#
# Order (all three run as the postgres superuser via peer auth on the
# CNPG pod's local Unix socket):
#   1. 000-create-role.sql — base role + schema grants
#   2. 001-prisma-baseline.sql — 14 CREATE TABLEs + indexes + FKs
#   3. 002-rls-policies.sql — ENABLE RLS + tenant_isolation policies
#
# Why all three use the superuser instead of OpenBao's
# `project-tracker-migrate` role:
#   - 000 needs CREATE ROLE (only superusers in CNPG)
#   - 001's leading `CREATE SCHEMA IF NOT EXISTS` requires CREATE on
#     the database, which the migrate role doesn't have (and shouldn't —
#     it has CREATE on the project_tracker schema only)
#   - 002 is just ALTER + CREATE POLICY which the migrate role could
#     run, but splitting between superuser + migrate inside one apply
#     pass adds plumbing for negligible gain.
#
# The peer-auth-via-local-socket path is already privilege-isolated:
# the postgres superuser is only reachable from inside the CNPG pod
# (no exposed superuser endpoint, no password-auth path). The
# `project-tracker-migrate` OpenBao role IS still provisioned in
# `infrastructure/project-tracker/provision-db-and-bao.sh` for the
# data-import step (003-import.sh), where short-lived creds + RLS-bypass
# via `SET LOCAL row_security=off` is the right shape.
#
# apply.sh is idempotent on 000 (DO IF NOT EXISTS / GRANT) but NOT on
# 001 — Prisma-generated CREATE TABLE has no IF NOT EXISTS guard, so
# a re-run will error on existing tables. To re-apply, drop the schema
# first (intentional — silent no-ops would mask mistakes).
#
# Pre-conditions:
#   - infrastructure/project-tracker/provision-db-and-bao.sh ran
#     (so the project-tracker-migrate / -readwrite roles exist for
#     when 003-import.sh and the runtime backend need them)
#
# Next: bash 003-import.sh (data import from local docker-compose)
#       bash 004-verify.sh (parity + RLS scoping verification)

set -euo pipefail

NS_APP=app
PG_POD=secforge-app-db-1
PG_DB=secforge_app

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

psql_super() {
    kubectl exec -i -n "$NS_APP" "$PG_POD" -c postgres -- \
        psql -U postgres -d "$PG_DB" -v ON_ERROR_STOP=1
}

# ─── Section 1 — apply 000 / 001 / 002 ───────────────────────────────
green "==> apply 000-create-role.sql (base role + schema grants)"
psql_super < "$HERE/000-create-role.sql" >/dev/null
green "    project_tracker_app role + schema USAGE/CREATE grants applied"

green "==> apply 001-prisma-baseline.sql (14 tables under project_tracker schema)"
psql_super < "$HERE/001-prisma-baseline.sql" >/dev/null
green "    14 CREATE TABLEs + indexes + FKs applied"

# Tables created by the superuser are owned by `postgres`. project_tracker_app
# (which runtime + migrate roles inherit) needs explicit DML grants to
# operate on them — RLS policies scope row visibility but don't substitute
# for table-level privileges. Grant per-table DML now (covers the 14 just
# created) AND set ALTER DEFAULT PRIVILEGES so any future tables created
# in this schema by `postgres` automatically pick up the same grants
# (matters for follow-up Prisma migrations promoted into 00N-*.sql files).
green "==> grant DML on project_tracker.* to project_tracker_app"
# UPDATE on sequences is required for setval() during data import
# (003-import.sh runs SELECT pg_catalog.setval('project_tracker.<seq>',
# ...) lines from pg_dump's preamble to preserve BIGSERIAL counters).
# USAGE is needed for nextval(), SELECT for currval().
psql_super >/dev/null <<'SQL'
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA project_tracker TO project_tracker_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA project_tracker TO project_tracker_app;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA project_tracker
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO project_tracker_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA project_tracker
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO project_tracker_app;
SQL
green "    DML + sequence grants applied; default-privileges set for future tables"

green "==> apply 002-rls-policies.sql (14 RLS policies)"
psql_super < "$HERE/002-rls-policies.sql" >/dev/null
green "    14 ALTER...ENABLE RLS + 14 CREATE POLICY applied"

# ─── Section 4 — verify ──────────────────────────────────────────────
green "==> verify schema state"
TABLE_COUNT=$(kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- \
    psql -U postgres -d "$PG_DB" -tA -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='project_tracker';" \
    | tr -d ' \r\n')
POLICY_COUNT=$(kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- \
    psql -U postgres -d "$PG_DB" -tA -c \
    "SELECT count(*) FROM pg_policies WHERE schemaname='project_tracker' AND policyname='tenant_isolation';" \
    | tr -d ' \r\n')

if [ "$TABLE_COUNT" != "14" ]; then
    red "expected 14 tables, found $TABLE_COUNT — investigate"; exit 1
fi
if [ "$POLICY_COUNT" != "14" ]; then
    red "expected 14 RLS policies, found $POLICY_COUNT — investigate"; exit 1
fi

green ""
green "Schema + RLS applied successfully."
green "  tables in project_tracker:        $TABLE_COUNT"
green "  tenant_isolation policies:        $POLICY_COUNT"
green ""
green "Next:"
green "  bash $HERE/003-import.sh   (data import from local docker-compose)"
green "  bash $HERE/004-verify.sh   (parity + RLS scoping verification)"
