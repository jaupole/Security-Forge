#!/usr/bin/env bash
# Phase 5.7 — enable secrets engines on the main OpenBao.
#
# Pre-conditions:
#   - openbao-{0,1,2} are unsealed and Raft healthy
#   - main OpenBao initial root token is in $BAO_TOKEN env (or pass on CLI)
#
# Engines:
#   secret/   kv-v2   (static credentials, signing keys, etc.)
#   transit/  transit (app-level encryption-as-a-service)
#   database/ database (dynamic Postgres credentials)
#
# For the database engine: configures secforge-app-db as a Postgres
# source. We use the `app` user from secforge-app-db-app (CNPG-issued)
# but FIRST grant CREATEROLE to it via psql, then immediately rotate
# the password so OpenBao owns the credential. This is the operational
# pattern documented in the OpenBao database engine docs ("rotate-root").

set -euo pipefail
NS=openbao
POD=openbao-0

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Pass the main OpenBao initial root token:\n"
    printf "  BAO_TOKEN=s.XXX bash configure-engines.sh\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# 1. KV-v2 at secret/.
green "==> enable kv-v2 at secret/"
if bao bao secrets list -format=json 2>/dev/null | grep -q '"secret/":'; then
    green "    already enabled"
else
    bao bao secrets enable -version=2 -path=secret kv 2>&1 | tail -1
fi

# 2. Transit (separate from the seal-OpenBao's Transit; this one is for apps).
green "==> enable transit/"
if bao bao secrets list -format=json 2>/dev/null | grep -q '"transit/":'; then
    green "    already enabled"
else
    bao bao secrets enable transit 2>&1 | tail -1
fi

# 2a. Create the pii-encryption key.
green "==> transit/keys/pii-encryption (aes256-gcm96)"
bao bao read transit/keys/pii-encryption >/dev/null 2>&1 || \
    bao bao write -f transit/keys/pii-encryption type=aes256-gcm96 2>&1 | tail -1

# 3. Database secrets engine.
green "==> enable database/"
if bao bao secrets list -format=json 2>/dev/null | grep -q '"database/":'; then
    green "    already enabled"
else
    bao bao secrets enable database 2>&1 | tail -1
fi

# 3a. Grant CREATEROLE to the `app` user in secforge-app-db so OpenBao
# can mint dynamic users. Idempotent.
#
# CNPG disables superuser-via-password by default; the postgres role
# is reachable only via peer auth on the local Unix socket inside the
# pod. We use that path to grant CREATEROLE to the `app` user.
green "==> grant CREATEROLE on app user (secforge-app-db)"
PG_PASS=$(kubectl get secret -n app secforge-app-db-app -o jsonpath='{.data.password}' | base64 -d)
PG_USER=$(kubectl get secret -n app secforge-app-db-app -o jsonpath='{.data.username}' | base64 -d)
kubectl exec -n app secforge-app-db-1 -c postgres -- \
    psql -U postgres -d secforge_app -c "ALTER USER $PG_USER WITH CREATEROLE;" 2>&1 | tail -1

# 3b. Configure the database connection. allowed_roles lists the
# OpenBao role names that can mint creds against this connection.
green "==> database/config/secforge-app"
bao bao write database/config/secforge-app \
    plugin_name=postgresql-database-plugin \
    allowed_roles="helloworld-app-readwrite,helloworld-app-readonly" \
    connection_url="postgresql://{{username}}:{{password}}@secforge-app-db-rw.app.svc.cluster.local:5432/secforge_app?sslmode=require" \
    username="$PG_USER" \
    password="$PG_PASS" 2>&1 | tail -1

# 3c. Rotate the bootstrap password — OpenBao now owns it.
# After this, no human can log into Postgres as `app` until OpenBao
# rotates it again or someone uses recovery procedures.
green "==> rotate-root for secforge-app-db (OpenBao now owns the password)"
bao bao write -force database/rotate-root/secforge-app 2>&1 | tail -1
unset PG_PASS PG_USER

# 3d. Define roles. helloworld-app-readwrite mints a per-request user
# with full DML on public schema. TTL 1h, max 24h.
green "==> database/roles/helloworld-app-readwrite"
bao bao write database/roles/helloworld-app-readwrite \
    db_name=secforge-app \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT USAGE ON SCHEMA public TO "{{name}}"; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{name}}"; GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO "{{name}}";' \
    revocation_statements='REASSIGN OWNED BY "{{name}}" TO postgres; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=24h 2>&1 | tail -1

green "==> database/roles/helloworld-app-readonly"
bao bao write database/roles/helloworld-app-readonly \
    db_name=secforge-app \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT USAGE ON SCHEMA public TO "{{name}}"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";' \
    revocation_statements='REASSIGN OWNED BY "{{name}}" TO postgres; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=24h 2>&1 | tail -1

# 4. Verify by minting a credential.
green "==> sanity check: mint a helloworld-app-readwrite credential"
bao bao read -format=json database/creds/helloworld-app-readwrite 2>&1 \
    | jq '.data | {username: .username, password_len: (.password | length)}'

green ""
green "Phase 5.7 + 5.11 complete. Audit live, kv-v2 + transit + database engines enabled."
