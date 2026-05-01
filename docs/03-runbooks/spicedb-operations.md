# SpiceDB Operations Runbook (Local Edition)

> Architecture: [docs/01-architecture/02-authorization.md](../01-architecture/02-authorization.md)
> ADR: [docs/02-decisions/0008-authz-schema.md](../02-decisions/0008-authz-schema.md)
> Schema: [infrastructure/spicedb/schema.zed](../../infrastructure/spicedb/schema.zed)
> Tests:  [infrastructure/spicedb/tests/](../../infrastructure/spicedb/tests/)

---

## Reach the cluster

All commands assume:
- `kubectl` on PATH, default context = Docker Desktop K8s
- Working directory: `infrastructure/spicedb/`
- The `spicedb-config-vso` Secret exists in `spicedb` ns (VSO-rendered from OpenBao path `secret/data/spicedb/config` per Phase 6.10b; see [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md)). Keys: `preshared_key`, `datastore_uri`.
- Docker available for one-shot zed/skopeo image runs

The drop-in zed CLI:

```bash
bash infrastructure/spicedb/zed.sh schema read
bash infrastructure/spicedb/zed.sh permission check document:welcome view user:jason
bash infrastructure/spicedb/zed.sh relationship create document:fresh owner user:eve --json
```

Each invocation spawns a one-shot pod (~5s). For batch operations, `kubectl exec` into the long-lived `zed-check-runner` pod that `check-permissions.sh` provisions.

---

## Routine operations

### Re-run the schema validators (no cluster needed)

```bash
bash infrastructure/spicedb/tests/run.sh
```

Each `*.yaml` file is a self-contained schema + relationships + assertions. Validates schema syntax, permission expressions, and the assert-true/assert-false outcomes.

### Apply a schema change

```bash
# 1. Edit infrastructure/spicedb/schema.zed
# 2. Add or update assertion files in infrastructure/spicedb/tests/
# 3. Validate locally
bash infrastructure/spicedb/tests/run.sh
# 4. Push to live SpiceDB
bash infrastructure/spicedb/apply-schema.sh
# 5. Confirm
bash infrastructure/spicedb/zed.sh schema read | diff - infrastructure/spicedb/schema.zed
```

Schema apply is idempotent: same schema is a no-op. Different schema goes through SpiceDB's schema-migration validation; relationships referencing removed types/relations cause the write to fail (preserves data integrity).

### Re-run Phase 4.5 verification

```bash
bash infrastructure/spicedb/check-permissions.sh
```

Runs:
- 7 baseline checks against the seed data (jason owner; alice viewer; bob no-relation)
- 4 cascade checks (tenant admin → app administer → resource edit/delete)
- 1 ZedToken read-your-writes consistency check

Spawns a long-lived `zed-check-runner` pod for the run; cleans it up on exit.

### Add a per-app resource type

Pattern (follow [ADR-0008](../02-decisions/0008-authz-schema.md)):

```zed
definition proposal {
    relation app:    app
    relation owner:  user
    relation reviewer: user
    relation reader:   user

    permission edit   = owner + app->administer
    permission review = owner + reviewer + app->administer
    permission view   = owner + reviewer + reader + app->administer + app->use
    permission delete = owner + app->administer
}
```

PR includes:
1. The new definition in `schema.zed`
2. New assertion files under `tests/` covering owner/editor/viewer + cascade
3. A note in `02-authorization.md` listing the new type

### Generate a fresh pre-shared key

```bash
NEW=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
# 1. Add the new key to the SpiceDB CR config (it accepts a list)
#    via spec.config.dispatchClusterEnabled and presharedKey list, or
#    via the `spicedb-config` Secret value (multiline = multiple keys).
kubectl -n spicedb patch secret spicedb-config --type=merge \
    -p "{\"data\":{\"preshared_key\":\"$(echo -n "$(kubectl get secret -n spicedb spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)
$NEW" | base64 -w 0)\"}}"
# 2. Restart SpiceDB to pick up both keys.
kubectl rollout restart -n spicedb deployment/spicedb-spicedb
# 3. Update all clients (AuthZEN façade, kcadm scripts, runbook helpers)
#    to use the NEW key. They keep the OLD key as a transitional credential.
# 4. After clients are confirmed on NEW, remove OLD from the Secret and
#    restart SpiceDB once more.
```

Phase 5 (OpenBao) replaces this manual rotation with a SPIFFE-bound dynamic credential.

### Backup the SpiceDB database

```bash
kubectl exec -n spicedb secforge-spicedb-db-1 -- \
    pg_dump -Fc -U spicedb spicedb > /tmp/spicedb-$(date +%Y%m%d).dump
```

Restore (destructive):

```bash
kubectl exec -i -n spicedb secforge-spicedb-db-1 -- \
    pg_restore --clean -U spicedb -d spicedb < /tmp/spicedb-DATE.dump
kubectl rollout restart -n spicedb deployment/spicedb-spicedb
```

### Inspect dispatch cache stats

```bash
kubectl exec -n spicedb deploy/spicedb-spicedb -- \
    wget -q -O - http://localhost:9090/metrics 2>/dev/null \
    | grep -E "^spicedb_(cache|dispatch)"
```

(Phase 7 wires Prometheus to scrape this; until then, ad-hoc inspection only.)

---

## Troubleshooting

### `connection error: desc = "error reading server preface: EOF"` from CheckPermission

SpiceDB's dispatch upstream is dialing its own dispatch port over TLS, but the CA path isn't configured. Confirm:

```bash
kubectl get spicedbcluster -n spicedb spicedb -o json \
    | jq -r '.spec.config.dispatchUpstreamCaPath'
# expected: /tls/ca.crt
```

If empty, edit `infrastructure/spicedb/04-spicedb-cr.yaml` to add the line, re-apply, and bounce the pod. The CA cert is mounted from the `spicedb-grpc-tls` cert-manager Secret.

### `context deadline exceeded while waiting for connections to become ready`

Two common causes:

1. **Dispatch cluster is `false` but upstream is set.** SpiceDB Operator's default sets `SPICEDB_DISPATCH_UPSTREAM_ADDR` regardless of `dispatchClusterEnabled`. Set `dispatchClusterEnabled: "true"` so the dispatch SERVER is on, and the self-loop succeeds. Captured in `04-spicedb-cr.yaml`.
2. **NetworkPolicy blocks self-dispatch (port 50053).** `allow-spicedb-self-dispatch` (in `05-networkpolicies.yaml`) must be present.

### `failed to create datastore: ... context deadline exceeded` at startup

NetworkPolicy is blocking SpiceDB → Postgres. Verify `allow-postgres-ingress` exists in `spicedb` ns selecting `cnpg.io/cluster: secforge-spicedb-db` and allowing `from: authzed.com/cluster: spicedb` on TCP/5432. (Same lesson as Phase 3.6 keycloak.)

### `failed to verify image` warnings on every pod create

Cosmetic — Kyverno's `verify-image-signatures` policy is in Audit mode (per [ADR-0004](../02-decisions/0004-kyverno-audit-mode.md)). It warns but doesn't block. Sign images at the production-hardening pass.

### Schema apply hangs / times out

The `apply-schema.sh` script spawns an ephemeral pod that pipes `schema.zed` over kubectl stdin. If the pod fails to start (e.g., Kyverno PSS policy block), the script appears to hang. Check:

```bash
kubectl get pods -n spicedb -l role=zed-cli-oneshot
```

If a `zed-write-schema` pod is in `Pending` / `Failed`, look at its events.

### `permission check ... -> false` when expected `true` (cascade not firing)

The cascade requires intermediate relations:
- `tenant:X#admin@user:Y` — Y is admin of tenant X
- `app:Z#tenant@tenant:X` — app Z is bound to tenant X
- `<resource>:R#app@app:Z` — resource R is bound to app Z

If any of these are missing, the cascade short-circuits to false. Re-run `infrastructure/spicedb/seed-test-data.sh` to ensure the baseline relationships are present, then check yours.

### "Acquisition timeout while waiting for new connection" from Postgres

Postgres connection pool exhaustion — typically because rapid pod restarts during a NetworkPolicy or CR change attempted multiple connection establishments. Check:

```bash
kubectl exec -n spicedb secforge-spicedb-db-1 -- \
    psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='spicedb' GROUP BY state;"
```

If close to `max_connections=100`, restart SpiceDB (`kubectl rollout restart`) to drain the pool.

---

## Re-deploying from scratch

```bash
# 1. Delete the SpiceDBCluster CR (operator-managed Deployment + Service go with it).
kubectl delete spicedbcluster -n spicedb spicedb

# 2. Drop the schema migration history (otherwise re-deploy thinks the
#    DB is already at HEAD and skips fresh-creation paths).
kubectl exec -n spicedb secforge-spicedb-db-1 -- \
    psql -U spicedb -d spicedb -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# 3. Re-apply Phase 4.3.
bash infrastructure/spicedb/apply.sh

# 4. Re-seed.
bash infrastructure/spicedb/apply-schema.sh
bash infrastructure/spicedb/seed-test-data.sh

# 5. Verify.
bash infrastructure/spicedb/check-permissions.sh
```

Destroys all relationships, schema state, and dispatch caches. Use only on a fresh dev environment or after backing up the DB.
