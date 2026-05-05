#!/usr/bin/env bash
# Phase 9.4a — provision the Postgres schema + OpenBao roles the
# helloworld-backend needs to function.
#
# What this creates (idempotent):
#
#   Postgres (in secforge_app):
#     - role  helloworld_app_owner   (NOLOGIN, schema/table owner)
#     - GRANT helloworld_app_owner TO app WITH ADMIN OPTION
#         (lets the OpenBao-connecting `app` user grant role membership
#          to dynamic users it mints; Postgres 16+ requires ADMIN OPTION
#          per the same constraint documented in
#          infrastructure/openbao/database-roles/spicedb-readwrite.sh)
#     - schema helloworld (owned by helloworld_app_owner)
#     - table  helloworld.documents (id, owner, content, updated_at)
#     - seed row ('welcome', 'jason@example.com', '<lorem ipsum>')
#
#   OpenBao:
#     - database/config/secforge-app
#         allowed_roles += helloworld-backend-readwrite
#     - database/roles/helloworld-backend-readwrite
#         creation_statements grant role membership in helloworld_app_owner
#         with INHERIT — dynamic user inherits owner privileges scoped to
#         the helloworld schema
#     - policy helloworld-backend  (loaded from policies/helloworld-backend.hcl)
#     - auth/jwt/role/helloworld-backend
#         bound_subject = spiffe://secforge.local/ns/app/sa/helloworld-backend
#         token_policies = [helloworld-backend]
#         token_ttl = 1h
#
# Pre-conditions:
#   - Phase 5.7 (configure-engines.sh) ran — secforge-app DB engine wired up
#   - Phase 5.8 (configure-auth-k8s-jwt.sh) ran — JWT auth method enabled
#   - BAO_TOKEN exported with admin-tier capabilities
#       (e.g. via `bao login -method=oidc role=admin`)
#
# Teardown:
#   Phase 9.12 (infrastructure/helloworld/teardown.sh) reverses everything
#   above: drops the OpenBao role/policy/JWT-role, removes the schema + the
#   helloworld_app_owner Postgres role.

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
green "==> Postgres: helloworld_app_owner role + schema + table + seed"

psql_postgres -c "DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'helloworld_app_owner') THEN
        CREATE ROLE helloworld_app_owner NOLOGIN;
    END IF;
END\$\$;" 2>&1 | tail -1

# Grant `app` admin option on the new role so it can grant membership
# during dynamic-cred mint. Idempotent: re-granting WITH ADMIN OPTION is
# a no-op if already in place.
psql_postgres -c "GRANT helloworld_app_owner TO app WITH ADMIN OPTION;" 2>&1 | tail -1

psql_postgres -c "CREATE SCHEMA IF NOT EXISTS helloworld AUTHORIZATION helloworld_app_owner;" 2>&1 | tail -1

# Create the table as helloworld_app_owner so the schema-owner owns the
# table (matters for grants on ALL TABLES via role membership).
psql_postgres <<'SQL' 2>&1 | tail -3
SET ROLE helloworld_app_owner;

CREATE TABLE IF NOT EXISTS helloworld.documents (
    id          text PRIMARY KEY,
    owner       text NOT NULL,
    content     text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO helloworld.documents (id, owner, content)
VALUES (
    'welcome',
    'jason@example.com',
    'Hello, world! This is the SecForge platform Phase 9 demo. The fact that you are reading this means: ' ||
    'OIDC + TOTP login through Keycloak, BFF session cookie, DPoP-bound JWT to the backend, JWT signature ' ||
    'verification against Keycloak JWKS, DPoP htm/htu/jti/iat replay protection, SpiceDB CheckPermission ' ||
    'against three-tier (tenant/app/document) authorization, and dynamic Postgres credentials minted by ' ||
    'OpenBao bound to a SPIFFE ID — all worked. The platform is operational.'
)
ON CONFLICT (id) DO NOTHING;

RESET ROLE;
SQL

# Verification
ROW_COUNT=$(psql_postgres -tA -c "SELECT count(*) FROM helloworld.documents WHERE id='welcome';" | tr -d ' \r\n')
if [ "$ROW_COUNT" != "1" ]; then
    red "seed verification failed (expected 1 row, got $ROW_COUNT)"
    exit 1
fi
green "    seed row ✓ helloworld.documents has welcome row"

# ─── Section 2 — OpenBao DB role ─────────────────────────────────────────
green "==> OpenBao: update database/config/secforge-app allowed_roles"

# Read current allowed_roles via host jq, append helloworld-backend-readwrite if missing.
CURRENT_JSON=$(bao bao read -format=json database/config/secforge-app 2>/dev/null)
CURRENT=$(echo "$CURRENT_JSON" | jq -r '.data.allowed_roles | join(",")')
yellow "    current allowed_roles: $CURRENT"

if echo ",$CURRENT," | grep -q ',helloworld-backend-readwrite,'; then
    green "    helloworld-backend-readwrite already in allowed_roles"
    NEW="$CURRENT"
else
    NEW="${CURRENT},helloworld-backend-readwrite"
    green "    appending helloworld-backend-readwrite (new list: $NEW)"
fi

# Re-write database/config keeping plugin_name + connection_url unchanged.
# OpenBao doesn't allow partial updates here — must repeat the full config.
# Username comes from the CNPG-issued Secret (kept here because OpenBao's
# password is still the rotate-rooted one from Phase 5.7; passing only
# username preserves the existing stored password).
PG_USER=$(kubectl get secret -n "$NS_APP" secforge-app-db-app -o jsonpath='{.data.username}' | base64 -d)
bao bao write database/config/secforge-app \
    plugin_name=postgresql-database-plugin \
    allowed_roles="$NEW" \
    connection_url="postgresql://{{username}}:{{password}}@secforge-app-db-rw.app.svc.cluster.local:5432/secforge_app?sslmode=require" \
    username="$PG_USER" 2>&1 | tail -1
unset PG_USER

green "==> OpenBao: database/roles/helloworld-backend-readwrite"
bao bao write database/roles/helloworld-backend-readwrite \
    db_name=secforge-app \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"' INHERIT; GRANT helloworld_app_owner TO "{{name}}";' \
    revocation_statements='REASSIGN OWNED BY "{{name}}" TO helloworld_app_owner; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=4h 2>&1 | tail -1

# Sanity-check: mint a credential, parse via host jq, revoke its lease so
# we don't leak a 1h-living dynamic role just to prove the path works.
green "==> OpenBao: sanity-mint helloworld-backend-readwrite credential"
MINT_JSON=$(bao bao read -format=json database/creds/helloworld-backend-readwrite) || {
    red "mint failed (see error above)"
    exit 1
}
USERNAME=$(echo "$MINT_JSON" | jq -r '.data.username')
LEASE_ID=$(echo "$MINT_JSON" | jq -r '.lease_id')
green "    minted ✓ username=$USERNAME"
bao bao lease revoke "$LEASE_ID" >/dev/null 2>&1 && green "    revoked ✓"

# ─── Section 3 — OpenBao policy ─────────────────────────────────────────
green "==> OpenBao: load policy helloworld-backend"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="$HERE/../openbao/policies/helloworld-backend.hcl"
if [ ! -f "$POLICY_FILE" ]; then
    red "policy file not found at $POLICY_FILE"
    exit 1
fi

# Stream the policy through bao policy write -.
kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -i -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao policy write helloworld-backend - <"$POLICY_FILE" 2>&1 | tail -1

# ─── Section 4 — JWT auth role ───────────────────────────────────────────
green "==> OpenBao: auth/jwt/role/helloworld-backend"
# token_ttl MUST exceed the dynamic-credential default_ttl (1h on
# database/roles/helloworld-backend-readwrite). OpenBao binds dynamic-
# credential leases to the requesting auth token; if the auth token
# expires before the credential, all child leases are revoked
# immediately. token_ttl=90m gives 30m headroom over the 1h credential
# lease, enough for the 28P01-retry path to mint a fresh credential.
# See infrastructure/openbao/configure-auth-jwt-roles.sh for the same
# pattern applied to spicedb-datastore-refresher.
bao bao write auth/jwt/role/helloworld-backend \
    role_type=jwt \
    bound_audiences=openbao \
    bound_subject="spiffe://secforge.local/ns/app/sa/helloworld-backend" \
    user_claim=sub \
    token_policies=helloworld-backend \
    token_ttl=90m \
    token_max_ttl=90m 2>&1 | tail -1

# Final summary.
green ""
green "Phase 9.4a complete. Backend will use:"
green "  - dynamic Postgres creds: bao read database/creds/helloworld-backend-readwrite"
green "  - SPIFFE-bound auth:      auth/jwt/role/helloworld-backend"
green ""
green "Next: 9.4 — implement apps/helloworld-backend in Go"
