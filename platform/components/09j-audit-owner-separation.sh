#!/usr/bin/env bash
# 09j — audit owner separation for Proposal Forge, Business Manager and
#       Project Manager (idempotent).
#
# Each app's login role used to own its own audit table, the functions behind
# the append-only protection, and the schema they live in — so the app's own
# database credentials could switch that protection off. This moves those
# objects to a per-app `<app>_audit_owner` role that nobody can log in as or
# SET ROLE to; the app keeps only what it needs (read, append, and the gated
# retention delete). What and why, per app: audit-owner-separation/<db>.sql.
#
#   09j-audit-owner-separation.sh                 apply to all three databases
#   09j-audit-owner-separation.sh business_manager          apply to one
#   09j-audit-owner-separation.sh --lend proposal_forge     lend the objects back
#                                                 to the app, to ship a migration
#                                                 that alters them; re-run without
#                                                 --lend afterwards
#
# Runs each script as the in-pod `postgres` superuser of the ecosystem-db
# cluster (peer auth inside the pod; no password, no OpenBao). Every apply ends
# with a posture check that raises if anything is off, so a clean run IS the
# verification; re-running is the periodic check.
#
# Order: each app must already be running its last audit migration (the
# scripts refuse otherwise). Runbook, rollback, and how to ship an audit
# migration afterwards: docs/03-runbooks/audit-owner-separation.md.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
SQL_DIR="$SCRIPT_DIR/audit-owner-separation"
NS=ecosystem-db
POD=ecosystem-db-1
ALL_DBS=(proposal_forge business_manager project_manager)

SUFFIX=".sql"
if [[ "${1:-}" == "--lend" ]]; then
  SUFFIX=".revert.sql"
  shift
  (( $# > 0 )) || { echo "ERR: --lend needs the database(s) to lend back, by name" >&2; exit 2; }
fi

DBS=("$@")
(( ${#DBS[@]} > 0 )) || DBS=("${ALL_DBS[@]}")

for db in "${DBS[@]}"; do
  file="$SQL_DIR/$db$SUFFIX"
  [[ -f "$file" ]] || { echo "ERR: no script for database '$db' ($file)" >&2; exit 2; }
done

for db in "${DBS[@]}"; do
  echo ">>> $db  ($db$SUFFIX)"
  kubectl exec -i -n "$NS" "$POD" -c postgres -- \
    psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q -f - < "$SQL_DIR/$db$SUFFIX"
done
