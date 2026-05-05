#!/usr/bin/env bash
# Phase 10.1.3 — provision the OpenBao engine roles, policy, and JWT
# auth role that project-tracker-backend needs to function. Mirrors
# infrastructure/helloworld/provision-db-and-bao.sh's shape.
#
# What this creates (idempotent):
#
#   Postgres (in secforge_app):
#     - role  project_tracker_app   (NOLOGIN, base role inherited by
#                                    runtime dynamic users; RLS policies
#                                    on project_tracker.* grant FOR ALL
#                                    TO this role)
#     - GRANT project_tracker_app TO app WITH ADMIN OPTION
#         (lets the OpenBao-connecting `app` user grant role membership
#          to dynamic users it mints; same Postgres-16+ ADMIN-OPTION
#          requirement as helloworld)
#
#   OpenBao:
#     - database/config/secforge-app
#         allowed_roles +=
#           project-tracker-readwrite,
#           project-tracker-migrate
#     - database/roles/project-tracker-readwrite
#         creation_statements grant role membership in project_tracker_app
#         with INHERIT — runtime dynamic user inherits the base role and
#         picks up the FOR-ALL-TO grants from RLS policies
#         default_ttl=1h, max_ttl=4h
#     - database/roles/project-tracker-migrate
#         creation_statements grant CREATE/ALTER/DROP on the
#         project_tracker schema; intended for short-lived migration
#         use only, not runtime
#         default_ttl=15m, max_ttl=1h
#     - policy project-tracker  (loaded from policies/project-tracker.hcl)
#     - auth/jwt/role/project-tracker
#         bound_subject = spiffe://secforge.local/ns/app/sa/project-tracker-backend
#         token_policies = [project-tracker]
#         token_ttl = 90m  (ADR-0025: token_ttl > credential default_ttl;
#                          the 90m here gives 30m headroom over the 1h
#                          runtime credential lease, enough for the
#                          28P01-retry refresh-on-AUTH-failure path)
#
# Pre-conditions:
#   - Phase 5.7 (configure-engines.sh) ran — secforge-app DB engine wired up
#   - Phase 5.8 (configure-auth-k8s-jwt.sh) ran — JWT auth method enabled
#   - BAO_TOKEN exported with admin-tier capabilities
#       (e.g. via `bao login -method=oidc role=admin`)
#
# This script runs ONCE during 10.1.3 cutover. The migrations under
# apps/project-tracker/migrations/ then use database/creds/project-tracker-migrate
# to apply the schema + RLS, and runtime project-tracker-backend uses
# database/creds/project-tracker-readwrite via the JWT auth role.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use:\n" >&2
    printf "  export BAO_ADDR=https://bao.secforge.local; export BAO_SKIP_VERIFY=1\n" >&2
    printf "  bao login -method=oidc role=admin -format=json | jq -r .auth.client_token > ~/.bao-token\n" >&2
    printf "  BAO_TOKEN=\$(cat ~/.bao-token) bash $(basename "$0")\n" >&2
    exit 1
fi

NS_BAO=openbao
BAO_POD=openbao-0
NS_APP=app
PG_POD=secforge-app-db-1
PG_DB=secforge_app

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

psql_postgres() {
    kubectl exec -i -n "$NS_APP" "$PG_POD" -c postgres -- \
        psql -U postgres -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"
}

# ─── Section 1 — Postgres setup ──────────────────────────────────────────
green "==> Postgres: project_tracker_app base role + GRANT-WITH-ADMIN-OPTION to app"

psql_postgres -c "DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'project_tracker_app') THEN
        CREATE ROLE project_tracker_app NOLOGIN;
    END IF;
END\$\$;" 2>&1 | tail -1

# Grant `app` admin option on the new role so it can grant membership
# during dynamic-cred mint. Idempotent.
psql_postgres -c "GRANT project_tracker_app TO app WITH ADMIN OPTION;" 2>&1 | tail -1

# Confirm the project_tracker schema exists (created at CNPG cluster
# bootstrap by infrastructure/cloudnativepg/clusters/app-db.yaml).
SCHEMA_PRESENT=$(psql_postgres -tA -c \
    "SELECT 1 FROM pg_namespace WHERE nspname='project_tracker';" \
    | tr -d ' \r\n')
if [ "$SCHEMA_PRESENT" != "1" ]; then
    red "project_tracker schema missing — should have been created at"
    red "CNPG bootstrap (see infrastructure/cloudnativepg/clusters/app-db.yaml"
    red "postInitApplicationSQL). Investigate before proceeding."
    exit 1
fi
green "    schema project_tracker present (owner: app)"

# Grant USAGE + CREATE on the schema to project_tracker_app so dynamic
# users (which inherit project_tracker_app) can resolve and create
# objects within. Migration credential needs CREATE; runtime credential
# falls back to the per-table FOR-ALL-TO grants from RLS policies.
psql_postgres -c "GRANT USAGE ON SCHEMA project_tracker TO project_tracker_app;" 2>&1 | tail -1
psql_postgres -c "GRANT CREATE ON SCHEMA project_tracker TO project_tracker_app;" 2>&1 | tail -1

# ─── Section 2 — OpenBao DB roles ─────────────────────────────────────────
green "==> OpenBao: update database/config/secforge-app allowed_roles"

CURRENT_JSON=$(bao bao read -format=json database/config/secforge-app 2>/dev/null)
CURRENT=$(echo "$CURRENT_JSON" | jq -r '.data.allowed_roles | join(",")')
yellow "    current allowed_roles: $CURRENT"

NEW="$CURRENT"
for role in project-tracker-readwrite project-tracker-migrate; do
    if echo ",$NEW," | grep -q ",$role,"; then
        green "    $role already in allowed_roles"
    else
        NEW="${NEW},${role}"
        green "    appending $role"
    fi
done

PG_USER=$(kubectl get secret -n "$NS_APP" secforge-app-db-app -o jsonpath='{.data.username}' | base64 -d)
bao bao write database/config/secforge-app \
    plugin_name=postgresql-database-plugin \
    allowed_roles="$NEW" \
    connection_url="postgresql://{{username}}:{{password}}@secforge-app-db-rw.app.svc.cluster.local:5432/secforge_app?sslmode=require" \
    username="$PG_USER" 2>&1 | tail -1
unset PG_USER

green "==> OpenBao: database/roles/project-tracker-readwrite (runtime, 1h)"
bao bao write database/roles/project-tracker-readwrite \
    db_name=secforge-app \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"' INHERIT; GRANT project_tracker_app TO "{{name}}";' \
    revocation_statements='REASSIGN OWNED BY "{{name}}" TO project_tracker_app; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=4h 2>&1 | tail -1

green "==> OpenBao: database/roles/project-tracker-migrate (migration-only, 15m)"
# The migrate user gets project_tracker_app membership (so it can resolve
# the schema + RLS) PLUS direct CREATE on the schema (for table creation).
# It does NOT get superuser; specifically NOT BYPASSRLS — RLS is disabled
# per-session via SET LOCAL row_security=off in 003-import.sh, so the
# import path doesn't trip on the policies it just installed.
bao bao write database/roles/project-tracker-migrate \
    db_name=secforge-app \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"' INHERIT; GRANT project_tracker_app TO "{{name}}"; GRANT CREATE ON SCHEMA project_tracker TO "{{name}}";' \
    revocation_statements='REASSIGN OWNED BY "{{name}}" TO project_tracker_app; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=15m \
    max_ttl=1h 2>&1 | tail -1

# Sanity-check both roles by minting + revoking.
green "==> OpenBao: sanity-mint project-tracker-readwrite"
MINT_JSON=$(bao bao read -format=json database/creds/project-tracker-readwrite) || {
    red "mint failed (see error above)"; exit 1; }
USERNAME=$(echo "$MINT_JSON" | jq -r '.data.username')
LEASE_ID=$(echo "$MINT_JSON" | jq -r '.lease_id')
green "    minted ✓ username=$USERNAME"
bao bao lease revoke "$LEASE_ID" >/dev/null 2>&1 && green "    revoked ✓"

green "==> OpenBao: sanity-mint project-tracker-migrate"
MINT_JSON=$(bao bao read -format=json database/creds/project-tracker-migrate) || {
    red "mint failed (see error above)"; exit 1; }
USERNAME=$(echo "$MINT_JSON" | jq -r '.data.username')
LEASE_ID=$(echo "$MINT_JSON" | jq -r '.lease_id')
green "    minted ✓ username=$USERNAME"
bao bao lease revoke "$LEASE_ID" >/dev/null 2>&1 && green "    revoked ✓"

# ─── Section 3 — OpenBao policy ─────────────────────────────────────────
green "==> OpenBao: load policy project-tracker"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="$HERE/../openbao/policies/project-tracker.hcl"
if [ ! -f "$POLICY_FILE" ]; then
    red "policy file not found at $POLICY_FILE"
    exit 1
fi

kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -i -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao policy write project-tracker - <"$POLICY_FILE" 2>&1 | tail -1

# ─── Section 4 — JWT auth role ───────────────────────────────────────────
green "==> OpenBao: auth/jwt/role/project-tracker"
# token_ttl = 90m mirrors the helloworld-backend pattern (ADR-0025):
# token_ttl > credential default_ttl ensures dynamic-cred leases survive
# the parent token's lifetime. 30m headroom over the 1h runtime credential
# default_ttl is enough for the 28P01-retry refresh path.
bao bao write auth/jwt/role/project-tracker \
    role_type=jwt \
    bound_audiences=openbao \
    bound_subject="spiffe://secforge.local/ns/app/sa/project-tracker-backend" \
    user_claim=sub \
    token_policies=project-tracker \
    token_ttl=90m \
    token_max_ttl=90m 2>&1 | tail -1

# Final summary.
green ""
green "Phase 10.1.3 OpenBao provisioning complete. project-tracker uses:"
green "  - runtime Postgres creds:    bao read database/creds/project-tracker-readwrite"
green "  - migration Postgres creds:  bao read database/creds/project-tracker-migrate"
green "  - SPIFFE-bound auth:         auth/jwt/role/project-tracker"
green ""
green "Next: bash apps/project-tracker/migrations/apply.sh (schema + RLS)"
green "      bash apps/project-tracker/migrations/003-import.sh (data)"
green "      bash apps/project-tracker/migrations/004-verify.sh (parity + RLS)"
