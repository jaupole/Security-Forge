# Postgres Instances (Local Edition)

CloudNativePG runs the operator in `postgres-operator`. Each application's database lives in its own `Cluster` custom resource, deployed into the consuming namespace. Cluster manifests are in [`infrastructure/cloudnativepg/clusters/`](../../infrastructure/cloudnativepg/clusters/).

This doc enumerates the instances, where their credentials live, and how to connect.

**No passwords appear in this document.** Connection strings reference Secret keys; `kubectl get secret -o jsonpath` is the only way to materialize them.

---

## Per-app instances

| Cluster name | Namespace | Database | Owner role | Storage | App-user Secret | Postgres version |
|---|---|---|---|---|---|---|
| `secforge-keycloak-db` | `keycloak` | `keycloak` | `keycloak` | 5 Gi | `secforge-keycloak-db-app` | 16.4 |
| `secforge-spicedb-db` | `spicedb` | `spicedb` | `spicedb` | 5 Gi | `secforge-spicedb-db-app` | 16.4 |
| `secforge-openbao-db` | `openbao` | `openbao` | `openbao` | 5 Gi | `secforge-openbao-db-app` | 16.4 |
| `secforge-app-db` | `app` | `secforge_app` | `app` | 5 Gi | `secforge-app-db-app` | 16.4 |
| `secforge-teleport-db` *(optional)* | `teleport` | `teleport` | `teleport` | 5 Gi | `secforge-teleport-db-app` | 16.4 |

**Per-app schemas** in `secforge_app`:
- `hello_world` — Phase 9 demo
- `proposal_forge` — first real app
- `project_tracker` — second real app

All owned by the `app` role. Apps set `search_path` explicitly; no cross-schema reads.

---

## Secret structure

CloudNativePG generates the app-user Secret with these keys (standard CNPG schema):

| Key | Contents |
|---|---|
| `username` | The owner role name (e.g. `keycloak`) |
| `password` | Random 64-char password, SCRAM-SHA-256 in pg_authid |
| `host` | `<cluster>-rw.<namespace>.svc` (read-write Service) |
| `port` | `5432` |
| `dbname` | The database name |
| `uri` | `postgresql://user:pass@host:5432/db` (URL-encoded) |
| `jdbc-uri` | `jdbc:postgresql://host:5432/db?user=...&password=...` |
| `pgpass` | Standard pgpass-format line |

CNPG also creates `<cluster>-server` (server TLS cert) and `<cluster>-replication` (replication user) Secrets — neither are touched by apps.

**Superuser access is disabled** (`spec.enableSuperuserAccess: false`) — there is no `<cluster>-superuser` secret. To run admin operations, exec into the pod and use the `postgres` system user via the local socket (no network listener for it).

---

## Connecting from another pod (in-cluster)

```bash
# Read the connection URI for SpiceDB
kubectl -n spicedb get secret secforge-spicedb-db-app \
  -o jsonpath='{.data.uri}' | base64 -d
```

Per-app deployments mount the relevant Secret as env vars. Example pattern (Helm values level):

```yaml
envFrom:
  - secretRef:
      name: secforge-spicedb-db-app
```

**TLS**: CNPG auto-issues a self-signed server certificate at `<cluster>-server`. Clients can verify against the CA bundle at the same secret (key: `ca.crt`). Phase 6 (Istio Ambient + SPIRE-issued service identities) layers mTLS on top, providing identity-bound encryption regardless of Postgres-level TLS.

---

## Operations

### Watch a cluster come up

```bash
kubectl -n keycloak get cluster secforge-keycloak-db -w
kubectl -n keycloak describe cluster secforge-keycloak-db
```

### Open a psql shell as the app user

```bash
NS=spicedb
CLUSTER=secforge-spicedb-db
SECRET="${CLUSTER}-app"
USER=$(kubectl -n $NS get secret $SECRET -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl -n $NS get secret $SECRET -o jsonpath='{.data.password}' | base64 -d)
DB=$(kubectl -n $NS get secret $SECRET -o jsonpath='{.data.dbname}' | base64 -d)
kubectl -n $NS exec -it ${CLUSTER}-1 -- env PGPASSWORD="$PASS" psql -U "$USER" -d "$DB"
```

### Backups

CNPG supports `Backup`/`ScheduledBackup` to S3-compatible storage. Phase 1 does not configure this — Phase 6 (after MinIO is wired through OpenBao for credentials) is the natural place. Document the gap until then.

### Migration to managed Postgres

When leaving local: each `Cluster` CR maps cleanly to an RDS / Cloud SQL instance. Application connection strings stay unchanged if you preserve the Secret name and keys (use ExternalSecrets to pull from the cloud provider's secret store).

---

## What's deliberately NOT here

- **No long-lived superuser credentials.** Phase 5 wires the OpenBao database secrets engine to issue short-lived per-session credentials; until then, the `enableSuperuserAccess: false` setting means there's no privileged credential to leak.
- **No HA / synchronous replication.** Single-node cluster means HA is theatre. Production gets `instances: 3` plus pgBouncer.
- **No connection pooling.** Add CNPG's `Pooler` CR per cluster when connection count becomes a problem (probably never, locally).
