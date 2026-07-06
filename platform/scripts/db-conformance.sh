#!/usr/bin/env bash
# db-conformance.sh — fleet database conformance harness (DB-UNIFICATION D9 /
# specs/data-standards.md §6). This is "the teeth": it introspects an app
# database (read-only) and fails if reality diverges from the app's declared
# db/conformance-manifest.json — killing the ORG_SCOPED_MODELS/FORCE_RLS_TABLES
# hand-list drift class of bug.
#
# Two run modes (the checks are identical):
#   --cluster  Run ON secforge against a live CNPG pod (per-cluster, read-only):
#                sudo bash db-conformance.sh --cluster \
#                  --ns member-hub --pod member-hub-db-1 --db member_hub \
#                  --manifest <path-to-conformance-manifest.json> \
#                  --migrations <dir> [--runtime-role member_hub_app]
#   --ci       Run in an app's CI against its migration-built DB via a DSN:
#                bash db-conformance.sh --ci --dsn "$DATABASE_URL" \
#                  --manifest db/conformance-manifest.json --migrations server/migrations
#
# Exit: 0 = conformant. 1 = one or more findings (printed). 2 = usage/setup error.
#
# Manifest schema (superset of the spec — see specs/data-standards.md §6):
#   app, guc,
#   org_scoped:          ["schema.table" | "table"]   (public. default)
#   org_scoped_indirect: {"table":"why it is FORCE+policy but has no org_id col"}
#   rls_exempt:          {"table":"why RLS is not the boundary"}
#   append_only:         ["schema.table"]
#   global_allowlist:    ["table"]   (platform/global, non-org — no RLS expected)
#   secret_allowlist:    {"schema.table.col":"why this *token*-named col is not a stored credential"}
#   migration_grandfather: ["052"]   (duplicate numeric prefixes predating the rule)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
SQL_FILE="$SCRIPT_DIR/db-conformance.sql"

MODE="" NS="" POD="" DB="" DSN="" MANIFEST="" MIGRATIONS="" RUNTIME_ROLE="" FACTS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) MODE=cluster ;;
    --ci) MODE=ci ;;
    --facts-file) MODE=facts; FACTS_FILE="$2"; shift ;;
    --ns) NS="$2"; shift ;;
    --pod) POD="$2"; shift ;;
    --db) DB="$2"; shift ;;
    --dsn) DSN="$2"; shift ;;
    --manifest) MANIFEST="$2"; shift ;;
    --migrations) MIGRATIONS="$2"; shift ;;
    --runtime-role) RUNTIME_ROLE="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$SQL_FILE" ] || { echo "missing $SQL_FILE" >&2; exit 2; }
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "missing --manifest" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

# ── run the introspection SQL, capture FACT lines ─────────────────────────────
run_facts() {
  case "$MODE" in
    cluster)
      [ -n "$NS$POD$DB" ] || { echo "--cluster needs --ns --pod --db" >&2; exit 2; }
      # Script runs ON the box, so a plain stdin redirect into `exec -i` is clean
      # (the heredoc-stdin hazard only applies to `ssh host <<EOF` wrappers).
      kubectl exec -i -n "$NS" "$POD" -c postgres -- \
        psql -U postgres -d "$DB" -X -q -At -P footer=off \
        -v runtime_role="$RUNTIME_ROLE" -f - < "$SQL_FILE"
      ;;
    ci)
      [ -n "$DSN" ] || { echo "--ci needs --dsn" >&2; exit 2; }
      psql "$DSN" -X -q -At -P footer=off \
        -v runtime_role="$RUNTIME_ROLE" -f "$SQL_FILE"
      ;;
    facts)
      # Pre-captured FACT lines (produced by this same SQL). Decouples capture
      # from evaluation — lets checks run where the DB is unreachable (and lets
      # CI cache one introspection across manifest edits).
      [ -f "$FACTS_FILE" ] || { echo "--facts-file not found: $FACTS_FILE" >&2; exit 2; }
      cat "$FACTS_FILE"
      ;;
    *) echo "need --cluster, --ci or --facts-file" >&2; exit 2 ;;
  esac
}

FACTS="$(run_facts)" || { echo "introspection query failed" >&2; exit 2; }

APP="$(jq -r '.app' "$MANIFEST")"
GUC="$(jq -r '.guc' "$MANIFEST")"
echo "── db-conformance: $APP (guc=$GUC) ───────────────────────────────"

FINDINGS=0 WARNINGS=0
fail() { echo "  ✗ [$1] $2"; FINDINGS=$((FINDINGS+1)); }         # isolation/secret → nonzero exit
warn() { echo "  ! [$1] $2"; WARNINGS=$((WARNINGS+1)); }         # standards/perf → reported, not fatal
info() { echo "  · $1"; }

# Manifest lookups. Table keys are matched both bare and schema-qualified; the
# harness normalizes a bare `t` to `public.t` and also accepts an explicit
# `schema.t` in the manifest.
mkey()   { jq -r --arg k "$1" '(.[$k] // []) | if type=="object" then keys[] else .[] end' "$MANIFEST" 2>/dev/null; }
in_list() { # $1=schema $2=table $3=manifest-key  → 0 if listed (bare or qualified)
  local q="$1.$2" b="$2"
  mkey "$3" | grep -qxF "$q" && return 0
  [ "$1" = public ] && mkey "$3" | grep -qxF "$b" && return 0
  return 1
}
classify() { # echoes the single category, or "UNCLASSIFIED"
  for cat in org_scoped org_scoped_indirect rls_exempt append_only global_allowlist; do
    in_list "$1" "$2" "$cat" && { echo "$cat"; return; }
  done
  echo UNCLASSIFIED
}

# ── Check 1: every table classified in exactly one bucket ─────────────────────
# ── Check 2/3: org_scoped shape (FORCE, org_id, index, policy, GUC) ───────────
declare -A POL_USING POL_CHECK
while IFS='|' read -r tag s t u c; do
  [ "$tag" = P ] || continue
  POL_USING["$s.$t"]="$u"; POL_CHECK["$s.$t"]="$c"
done <<< "$FACTS"

while IFS='|' read -r tag s t enabled forced has_org npol gucs org_idx; do
  [ "$tag" = T ] || continue
  cat="$(classify "$s" "$t")"
  case "$cat" in
    UNCLASSIFIED)
      fail C1 "$s.$t is not classified in the manifest (org_scoped/rls_exempt/append_only/global_allowlist)"
      ;;
    org_scoped)
      [ "$forced" = t ]   || fail C2 "$s.$t org_scoped but NOT FORCE RLS (enabled=$enabled)"
      [ "$has_org" = t ]  || fail C2 "$s.$t org_scoped but has no org_id column (use org_scoped_indirect if scoped by FK)"
      [ "$npol" -ge 1 ]   || fail C2 "$s.$t org_scoped but has no RLS policy"
      # A missing org_id index does NOT weaken isolation (the policy still
      # filters); it's a §3-template perf/standards gap → warn, don't fail.
      [ "$org_idx" = t ]  || warn C2i "$s.$t org_scoped but has no index on org_id (perf; §3 template)"
      [ "${POL_USING[$s.$t]:-f}" = t ] \
        || fail C2 "$s.$t has no policy with a GUC-referencing USING (tenant read predicate)"
      [ "${POL_CHECK[$s.$t]:-f}" = t ] \
        || fail C2 "$s.$t has no policy with a GUC-referencing WITH CHECK (cross-org INSERT/UPDATE guard)"
      if [ -n "$gucs" ] && ! grep -qw "$GUC" <<< "${gucs//,/ }"; then
        fail C3 "$s.$t policy GUC(s) [$gucs] != manifest guc [$GUC]"
      fi
      ;;
    org_scoped_indirect)
      [ "$forced" = t ] || fail C2 "$s.$t org_scoped_indirect but NOT FORCE RLS"
      [ "$npol" -ge 1 ] || fail C2 "$s.$t org_scoped_indirect but has no RLS policy"
      ;;
    append_only)
      [ "$forced" = t ] || info "$s.$t append_only, ENABLE-only (not FORCE) — acceptable if definer-written; noted"
      ;;
    rls_exempt)
      # Surface (do not fail) an exempt table that still carries org_id — it is a
      # standing "confirm RLS really isn't the boundary here" review item.
      [ "$has_org" = t ] && info "$s.$t rls_exempt but HAS org_id — confirm RLS not required (review)"
      ;;
    global_allowlist) : ;;  # rationale carried in the manifest
  esac
done <<< "$FACTS"

# ── Check 5: append_only tables have no UPDATE/DELETE grants (beyond owner) ────
while IFS='|' read -r tag s t grantee priv; do
  [ "$tag" = W ] || continue
  if in_list "$s" "$t" append_only; then
    fail C5 "$s.$t is append_only but grants $priv to role '$grantee'"
  fi
done <<< "$FACTS"

# ── Check 4: runtime role is not super/bypassrls and owns no org_scoped table ──
if [ -n "$RUNTIME_ROLE" ]; then
  while IFS='|' read -r tag rn super bypass; do
    [ "$tag" = R ] || continue
    [ "$super" = f ]  || fail C4 "runtime role '$rn' is SUPERUSER"
    [ "$bypass" = f ] || fail C4 "runtime role '$rn' has BYPASSRLS"
  done <<< "$FACTS"
  while IFS='|' read -r tag s t owner; do
    [ "$tag" = O ] || continue
    if [ "$owner" = "$RUNTIME_ROLE" ] && in_list "$s" "$t" org_scoped; then
      fail C4 "runtime role '$RUNTIME_ROLE' OWNS org_scoped table $s.$t (owner bypasses FORCE RLS)"
    fi
  done <<< "$FACTS"
fi

# ── Check 7: secret-named columns must be allowlisted ─────────────────────────
while IFS='|' read -r tag col; do
  [ "$tag" = S ] || continue
  jq -e --arg c "$col" '(.secret_allowlist // {}) | has($c)' "$MANIFEST" >/dev/null \
    || fail C7 "secret-named column '$col' is not in secret_allowlist (encrypt/drop it, or justify)"
done <<< "$FACTS"

# ── Check 6: migration-number collisions (filesystem) ─────────────────────────
if [ -n "$MIGRATIONS" ] && [ -d "$MIGRATIONS" ]; then
  GRAND="$(jq -r '(.migration_grandfather // []) | .[]' "$MANIFEST")"
  # Count each migration once by its numeric prefix, ignoring rollback twins
  # (`*.down.sql`) which legitimately share the number of their up-migration.
  DUPES="$(ls -1 "$MIGRATIONS" 2>/dev/null \
    | grep -vE '\.down\.(sql|ts|js)$' \
    | grep -oE '^[0-9]+' | sort | uniq -d)"
  for d in $DUPES; do
    grep -qxF "$d" <<< "$GRAND" && { info "migration prefix $d duplicated (grandfathered)"; continue; }
    fail C6 "duplicate migration number prefix '$d' in $MIGRATIONS"
  done
fi

echo "──────────────────────────────────────────────────────────────────"
if [ "$FINDINGS" -eq 0 ]; then
  echo "  ✓ $APP conformant${WARNINGS:+ ($WARNINGS warning(s))}"
  [ "$WARNINGS" -gt 0 ] && echo "  ($WARNINGS non-fatal standards warning(s) — tracked, not blocking)"
  exit 0
fi
echo "  $FINDINGS finding(s), $WARNINGS warning(s) for $APP"
exit 1
