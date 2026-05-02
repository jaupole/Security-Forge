#!/usr/bin/env bash
# Phase 7d.2.b — register the secforge-spicedb DB connection + the
# spicedb-readwrite role in OpenBao's database secrets engine.
#
# This script mirrors the Phase 5.7 setup for secforge-app
# (configure-engines.sh §3a-3d), with two differences:
#
#   1. The CNPG cluster is `secforge-spicedb-db` in the `spicedb` ns,
#      and the database+app-user is `spicedb` (per the CNPG cluster's
#      bootstrap.initdb config).
#
#   2. The role's creation_statements use Postgres role membership
#      (`GRANT spicedb TO "{{name}}"; ... INHERIT;`) rather than
#      explicit per-object GRANTs. This is necessary because SpiceDB
#      schema MIGRATIONS need ALTER on existing tables, and Postgres
#      does NOT have a GRANT for ALTER — only owners can ALTER. By
#      making the dynamic user a member of `spicedb` (the schema
#      owner) with INHERIT, the dynamic user gets ownership-tier
#      privileges including ALTER, without needing to be the table
#      owner directly. Runtime DML inherits transparently as well.
#
# Same idempotency guarantees as configure-engines.sh:
#   - psql ALTER USER ... CREATEROLE: idempotent.
#   - bao write database/config/...: idempotent (overwrites).
#   - bao write -force database/rotate-root/...: ONE-WAY — once OpenBao
#     owns the password, re-running re-rotates and *invalidates* any
#     prior OpenBao stored cred. Safe to re-run only because OpenBao
#     immediately stores the new value. Never run rotate-root from a
#     terminal that is not synchronized with `database/config` write.
#   - bao write database/roles/...: idempotent (overwrites).
#
# Pre-conditions:
#   - secforge-spicedb-db CNPG cluster is healthy
#     (kubectl get cluster -n spicedb shows "Cluster in healthy state")
#   - OpenBao database/ engine is enabled (Phase 5.7 §3 already did
#     this — all CNPG-backed connections share the same engine mount)
#   - BAO_TOKEN exported with admin-tier capabilities (or at least
#     write on database/config/* and database/roles/*)
#
# Auth:
#   BAO_TOKEN — admin token (e.g. `bao login -method=oidc role=admin`).

set -euo pipefail
NS=openbao
POD=openbao-0

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use the admin OIDC token:\n" >&2
    printf "  bao login -method=oidc role=admin\n" >&2
    printf "  export BAO_TOKEN=\$(bao print token)\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# 1. Sanity-check the database engine is mounted.
if ! bao bao secrets list -format=json 2>/dev/null | grep -q '"database/":'; then
    red "database/ engine not mounted on main OpenBao"
    red "Run infrastructure/openbao/configure-engines.sh first (Phase 5.7)."
    exit 1
fi

# 2. Grant CREATEROLE to the `spicedb` user via psql peer-auth inside the
#    CNPG postgres pod. Required because OpenBao's connection user must
#    be able to CREATE ROLE for dynamic-credential issuance, and
#    enableSuperuserAccess=false means no postgres-via-password.
green "==> grant CREATEROLE on spicedb user (secforge-spicedb-db)"
PG_PASS=$(kubectl get secret -n spicedb secforge-spicedb-db-app -o jsonpath='{.data.password}' | base64 -d)
PG_USER=$(kubectl get secret -n spicedb secforge-spicedb-db-app -o jsonpath='{.data.username}' | base64 -d)
if [ -z "$PG_USER" ] || [ -z "$PG_PASS" ]; then
    red "could not read username+password from secforge-spicedb-db-app Secret"
    exit 1
fi
kubectl exec -n spicedb secforge-spicedb-db-1 -c postgres -- \
    psql -U postgres -d spicedb -c "ALTER USER $PG_USER WITH CREATEROLE;" 2>&1 | tail -1

# 3. Configure the database connection. allowed_roles names every
#    OpenBao role permitted to mint creds against this connection.
green "==> database/config/secforge-spicedb"
bao bao write database/config/secforge-spicedb \
    plugin_name=postgresql-database-plugin \
    allowed_roles="spicedb-readwrite" \
    connection_url="postgresql://{{username}}:{{password}}@secforge-spicedb-db-rw.spicedb.svc.cluster.local:5432/spicedb?sslmode=require" \
    username="$PG_USER" \
    password="$PG_PASS" 2>&1 | tail -1

# 4. (NOT) rotate-root.
#
# Phase 5.7's helloworld-app pattern includes a `rotate-root` step here
# so OpenBao claims ownership of the postgres-side password. We deliberately
# DO NOT do that during this bootstrap, because:
#
#   - SpiceDB IS already deployed and IS already authenticating to
#     postgres via the static `datastore_uri` in spicedb-config-vso. That
#     URI carries the SAME password OpenBao currently has stored (the
#     CNPG-issued original).
#   - rotate-root would change the postgres-side password immediately.
#     Existing SpiceDB connections (already authenticated) survive, but
#     every new connection from SpiceDB would fail SASL until the K8s
#     Secret refreshes with a fresh dynamic cred.
#   - The Phase 7d.2.c CronJob is what refreshes that Secret. Until the
#     CronJob runs at least once on dynamic creds, rotating the postgres
#     password breaks SpiceDB.
#
# Operationally: bootstrap finishes here (config + role), then the CronJob
# is deployed (Phase 7d.2.c) and runs once to refresh the K8s Secret with
# a dynamic cred. SpiceDB rolls to dynamic creds. Only THEN is it safe to
# run rotate-root — see infrastructure/openbao/database-roles/rotate-root-secforge-spicedb.sh
# (a separate one-shot script intentionally NOT chained to this bootstrap).
#
# For local edition the rotate-root step is essentially a hygiene
# upgrade (ensures OpenBao "owns" the password vs. CNPG having issued
# it once and then ignored it). No security regression at the
# functional level — the dynamic-cred minting works regardless.
unset PG_PASS PG_USER

# 5. Define the spicedb-readwrite role.
#
# Postgres 16+ requires ADMIN OPTION on a role to grant membership in
# it. Even when the connecting user IS that role, self-grant requires
# admin option (which CNPG-issued users do not have on themselves). So
# the original `GRANT spicedb TO "{{name}}"` plan fails with
# `permission denied to grant role "spicedb"` (SQLSTATE 42501).
#
# Workaround: use explicit per-object GRANTs (the same pattern Phase
# 5.7's helloworld-app-readwrite uses). This covers the SpiceDB
# RUNTIME (DML on existing tables) but does NOT cover schema
# MIGRATIONS during SpiceDB Operator version upgrades — Postgres has
# no ALTER privilege; only the table OWNER can ALTER. SpiceDB upgrade
# procedure must temporarily use the static `spicedb` user for the
# migration job, then revert to dynamic creds. Documented in the
# spicedb-operations runbook (Phase 7d.3).
#
# Revocation: GRANT the dynamic role to `spicedb` first (the role
# CREATOR — the connecting `spicedb` user — implicitly has admin option
# on roles it created, so this self-grant works), then REASSIGN OWNED
# BY → spicedb. For runtime usage where the dynamic user never CREATEs
# objects, REASSIGN+DROP OWNED are no-ops; defense-in-depth in case
# future spicedb schemas have the dynamic user creating temp objects.
#
# default_ttl: 1h. max_ttl: 24h. Matches helloworld-app-readwrite.
# The 24h max_ttl is what the Phase 7d.2.c CronJob's 12h cadence
# is calibrated against (12h overlap window).
green "==> database/roles/spicedb-readwrite"
bao bao write database/roles/spicedb-readwrite \
    db_name=secforge-spicedb \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT USAGE ON SCHEMA public TO "{{name}}"; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{name}}"; GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";' \
    revocation_statements='GRANT "{{name}}" TO spicedb; REASSIGN OWNED BY "{{name}}" TO spicedb; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=24h 2>&1 | tail -1

# 6. Sanity-check: mint one credential and confirm we get back a username
#    + password pair. Don't print the password.
green "==> sanity check: mint a spicedb-readwrite credential"
bao bao read -format=json database/creds/spicedb-readwrite 2>&1 \
    | jq '.data | {username: .username, password_len: (.password | length)}'

green ""
green "Phase 7d.2.b complete. Connection + role registered."
green ""
green "Next:"
green "  - kubectl apply -f infrastructure/spicedb/06-vso-binding.yaml   # Phase 7d.2.c"
green "  - update infrastructure/openbao/policies/spicedb-vso.hcl to allow"
green "      database/creds/spicedb-readwrite"
green "  - smoke test via Phase 7d.2.e"
green ""
