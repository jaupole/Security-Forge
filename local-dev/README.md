# Local-dev (ecosystem)

Phase 0 of the ecosystem plan. Brings up a local Keycloak realm
(`secforge-tenants`) for the multi-app ecosystem (proposalapp,
managerapp, portal). SpiceDB and Postgres run native (no Docker).

## Prerequisites

- Docker Desktop (or compatible engine) — only required for the
  Keycloak container
- A native Postgres install on `localhost:5432` (used by Project
  Tracker / Proposal Forge already)
- Free TCP ports: `8080` (Keycloak HTTP), `9000` (Keycloak management
  health), `50051` (SpiceDB gRPC, run separately)

## Hosts file entries

Add these to `C:\Windows\System32\drivers\etc\hosts` (Windows) or
`/etc/hosts` (mac/linux):

```
127.0.0.1  auth.localhost
127.0.0.1  portal.localhost
127.0.0.1  proposalapp.localhost
127.0.0.1  managerapp.localhost
```

`*.localhost` resolution works without the hosts file on most
systems, but explicit entries make tooling behave consistently.

## Bring up

```bash
docker compose -f local-dev/docker-compose.dev.yml up -d
# Wait ~20s for Keycloak to be ready, then:
./local-dev/bootstrap-realm.sh
```

The bootstrap script prints the `ecosystem-control` client secret —
copy it into `Ecosystem Control/.env` as
`KEYCLOAK_ADMIN_CLIENT_SECRET`.

## SpiceDB (separate from this compose)

SpiceDB runs as a native binary, not in Docker. Per the plan §5
("Local Dev Setup — Minimal Docker"):

```bash
# Once: download from https://github.com/authzed/spicedb/releases
# and put `spicedb` somewhere on PATH.
spicedb serve \
  --grpc-preshared-key=local-dev-key \
  --datastore-engine=memory
```

Apply the schema (after both Keycloak and SpiceDB are up):

```bash
zed --endpoint=localhost:50051 --token=local-dev-key --insecure \
  schema write < ../infrastructure/spicedb/ecosystem-schema.zed
```

(Phase 0 uses in-memory datastore for rapid iteration; switch to
`postgres` engine in Phase 1+ when state needs to survive restarts.)

## Tear down

```bash
# Stop containers, keep data:
docker compose -f local-dev/docker-compose.dev.yml down

# Wipe everything (start fresh):
docker compose -f local-dev/docker-compose.dev.yml down -v
```

## What lives where

| File | Purpose |
|---|---|
| `docker-compose.dev.yml` | The ONE Keycloak container. |
| `bootstrap-realm.sh` | One-shot kcadm script: realm + Organizations enabled + portal/control clients. |
| `../infrastructure/spicedb/ecosystem-schema.zed` | SpiceDB authorization schema for the ecosystem (apply via `zed schema write`). |

## Why dev mode + in-memory DB

Keycloak's `start-dev` mode skips production hardening (TLS
required, hostname strict, etc.) and uses an in-memory H2 datastore.
For Phase 0 this is the right tradeoff: fast cold start, no
persistence pain, mirrors the realm shape we'll deploy to k3s in
Phase 9. The persistent volume `secforge-keycloak-dev-data` is for
test users you create through the realm so they survive a `down`
without `-v`.
