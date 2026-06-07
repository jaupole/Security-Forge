# SpiceDB Operations Runbook

> **Production note.** Written for the local edition. In production: SpiceDB is v1.51.1 (operator v1.24.0), CNPG-backed; the cluster is **Hetzner k3s**; operator access is the **Tailscale tailnet**. Verify steps against the live cluster before acting. See [PLAN.md](../../PLAN.md).

> Architecture: [docs/01-architecture/02-authorization.md](../01-architecture/02-authorization.md)
> ADR: [docs/02-decisions/0008-authz-schema.md](../02-decisions/0008-authz-schema.md)
> Schema: [platform/manifests/spicedb/schema.zed](../../platform/manifests/spicedb/schema.zed)
> Tests:  [platform/manifests/spicedb/tests/](../../platform/manifests/spicedb/tests/)

---

## Reach the cluster

All commands assume:
- `kubectl` on PATH, default context = Docker Desktop K8s
- Working directory: `platform/manifests/spicedb/`
- The `spicedb-config-vso` Secret exists in `spicedb` ns. Keys: `preshared_key`, `datastore_uri`. **As of Phase 7d.2 (ADR-0023, amended 2026-05-03):** the underlying OpenBao KV path `secret/data/spicedb/config` is **periodically re-populated** by the `spicedb-datastore-refresher` CronJob, which mints fresh dynamic Postgres credentials from `database/creds/spicedb-readwrite` (combined with the still-static PSK) every 12 hours. The role's `default_ttl=14h` exceeds the cron interval by 2h so each newly-minted credential outlives the next refresh — the OLD credential stays alive while the NEW one rolls into the K8s Secret. VSO refreshes the rendered Secret on KV-version bump → SpiceDB Operator's `secretName` watch fires → SpiceDB pod rolls with the new credential. CNPG-side password rotation is a separate concern handled by re-running the bootstrap (see § "CNPG password rotation" below). See [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md) for the broader VSO/direct-API split and [ADR-0023](../02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md) for why this is a CronJob-refreshed VaultStaticSecret rather than a native VaultDynamicSecret + the 2026-05-03 TTL bug-fix amendment.
- Docker available for one-shot zed/skopeo image runs

The drop-in zed CLI:

```bash
bash platform/manifests/spicedb/zed.sh schema read
bash platform/manifests/spicedb/zed.sh permission check document:welcome view user:jason
bash platform/manifests/spicedb/zed.sh relationship create document:fresh owner user:eve --json
```

Each invocation spawns a one-shot pod (~5s). For batch operations, `kubectl exec` into the long-lived `zed-check-runner` pod that `check-permissions.sh` provisions.

---

## Routine operations

### Re-run the schema validators (no cluster needed)

```bash
bash platform/manifests/spicedb/tests/run.sh
```

Each `*.yaml` file is a self-contained schema + relationships + assertions. Validates schema syntax, permission expressions, and the assert-true/assert-false outcomes.

### Apply a schema change

```bash
# 1. Edit platform/manifests/spicedb/schema.zed
# 2. Add or update assertion files in platform/manifests/spicedb/tests/
# 3. Validate locally
bash platform/manifests/spicedb/tests/run.sh
# 4. Push to live SpiceDB
bash platform/manifests/spicedb/apply-schema.sh
# 5. Confirm
bash platform/manifests/spicedb/zed.sh schema read | diff - platform/manifests/spicedb/schema.zed
```

Schema apply is idempotent: same schema is a no-op. Different schema goes through SpiceDB's schema-migration validation; relationships referencing removed types/relations cause the write to fail (preserves data integrity).

### Re-run Phase 4.5 verification

```bash
bash platform/manifests/spicedb/check-permissions.sh
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

> **Note (Phase 7d.2):** the procedure above patches a Secret that no longer exists by that name (`spicedb-config` → `spicedb-config-vso` after Phase 6.10b). Direct patches to `spicedb-config-vso` are reverted by VSO's next refresh. The current PSK rotation procedure is to write a new value to `secret/data/spicedb/preshared-key` in OpenBao; VSO renders the change. PSK rotation runbook update is on the operator backlog (the existing AuthZEN coupling — both SpiceDB and AuthZEN read from `secret/data/spicedb/preshared-key` — must be rotated together).

### Rotate the Postgres `datastore_uri` (Phase 7d.2 — automated)

Routine rotation runs automatically every 12h via the `spicedb-datastore-refresher` CronJob. There is **no operator action required** for steady-state rotation.

To trigger an immediate rotation off-cycle (e.g., after suspected database-credential compromise):

```bash
kubectl create job -n spicedb spicedb-datastore-refresher-manual-$(date +%s) \
    --from=cronjob/spicedb-datastore-refresher
```

Then watch the rendered Secret bump and the SpiceDB pod roll:

```bash
kubectl get jobs -n spicedb -l app.kubernetes.io/name=spicedb-datastore-refresher \
    --watch
kubectl logs -n spicedb -l app.kubernetes.io/name=spicedb-datastore-refresher --tail=20
kubectl rollout status -n spicedb deployment/spicedb-spicedb --timeout=180s
```

The refresher logs are structured JSON with discriminator `event=spicedb.datastore.refresh.<step|success|failed>`. Promtail picks them up; query in Loki:

```logql
{namespace="spicedb", app_kubernetes_io_name="spicedb-datastore-refresher"}
    | json | severity="error"
```

### Recover from CNPG-side `spicedb` user password rotation

If the CNPG `secforge-spicedb-db` cluster's `spicedb` user password is rotated outside OpenBao (e.g., by an operator running `ALTER USER spicedb WITH PASSWORD ...` directly, or by a CNPG version upgrade that re-issues credentials), OpenBao's stored connection root credential goes stale and **the next `spicedb-datastore-refresher` run will fail** with a SASL authentication error. The static `datastore_uri` in the rendered Secret continues to work for SpiceDB (it carries the same password OpenBao knows about, until VSO renders a new dynamic-cred-based URI), but new dynamic-cred mints are blocked.

Recovery procedure (mirrors the `spicedb-readwrite` OpenBao database role, provisioned by `platform/components/05c-openbao-configure.sh`):

```bash
# 1. Read the current CNPG-issued password.
PG_PASS=$(kubectl get secret -n spicedb secforge-spicedb-db-app -o jsonpath='{.data.password}' | base64 -d)
PG_USER=$(kubectl get secret -n spicedb secforge-spicedb-db-app -o jsonpath='{.data.username}' | base64 -d)

# 2. Mint an admin-tier OpenBao token (any of the standard paths — admin OIDC,
#    admin-break-glass via Kubernetes auth, etc.).
TOK=...   # see openbao-recovery.md

# 3. Update the connection's stored credential. allowed_roles / connection_url
#    do not change.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$TOK" \
    bao write database/config/secforge-spicedb \
        plugin_name=postgresql-database-plugin \
        allowed_roles="spicedb-readwrite" \
        connection_url="postgresql://{{username}}:{{password}}@secforge-spicedb-db-rw.spicedb.svc.cluster.local:5432/spicedb?sslmode=require" \
        username="$PG_USER" \
        password="$PG_PASS"
unset PG_PASS PG_USER

# 4. Verify a credential mint succeeds.
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$TOK" \
    bao read database/creds/spicedb-readwrite

# 5. Trigger an immediate refresher run so SpiceDB picks up a fresh dynamic
#    cred (the stale dynamic cred from before the rotation may still be valid
#    on the postgres side until its lease expires; this short-circuits to the
#    new cycle).
kubectl create job -n spicedb spicedb-datastore-refresher-recovery-$(date +%s) \
    --from=cronjob/spicedb-datastore-refresher
```

This is the same shape as Phase 5.7 follow-up #16 for the `secforge-app` connection (per [PLAN.md operator-backlog #16](../../PLAN.md)) — the OpenBao database engine assumes static root credentials at the postgres level, so any out-of-band rotation requires a re-bootstrap step. Cloud-edition migration should evaluate RDS IAM auth or equivalent to remove this coupling (see [ADR-0023 § Consequences → Future work](../02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md)).

### SpiceDB schema migration during operator upgrades

The dynamic-cred role `spicedb-readwrite` grants explicit DML privileges (SELECT/INSERT/UPDATE/DELETE on `public.*`) but **does not** grant the table OWNER privileges that SpiceDB Operator's migration job needs for `ALTER TABLE` during version upgrades. (Postgres has no `GRANT ALTER`; only the table owner can ALTER.) When upgrading SpiceDB:

1. Suspend the `spicedb-datastore-refresher` CronJob: `kubectl patch cronjob -n spicedb spicedb-datastore-refresher --type=merge -p '{"spec":{"suspend":true}}'`.
2. Manually update the rendered `spicedb-config-vso` Secret to use the static `spicedb` user credentials (read from `secforge-spicedb-db-app`). VSO will revert this on its next refresh, so disable the underlying VaultStaticSecret too: `kubectl patch vaultstaticsecret -n spicedb spicedb-config-vso --type=merge -p '{"spec":{"refreshAfter":"24h"}}'`. (This buys you a 24h window.)
3. Apply the SpiceDB Operator version bump and let the migration job complete.
4. Restore the `VaultStaticSecret` `refreshAfter` and unsuspend the CronJob.
5. Trigger an immediate refresher run to flip back to dynamic creds.

This is documented as a known sharp edge in [ADR-0023](../02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md). A future enhancement could template `creation_statements` to add the dynamic user as a member of `spicedb` via the role-creation `WITH ADMIN OPTION` flow (Postgres 16+ requirement) — but that pattern hit the SQLSTATE 42501 wall during Phase 7d.2 bootstrap; the explicit-grants approach was chosen for stability.

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

If empty, edit `platform/manifests/spicedb/04-spicedb-cr.yaml` to add the line, re-apply, and bounce the pod. The CA cert is mounted from the `spicedb-grpc-tls` cert-manager Secret.

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

If any of these are missing, the cascade short-circuits to false. Re-run `platform/manifests/spicedb/seed-test-data.sh` to ensure the baseline relationships are present, then check yours.

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
bash platform/manifests/spicedb/apply.sh

# 4. Re-seed.
bash platform/manifests/spicedb/apply-schema.sh
bash platform/manifests/spicedb/seed-test-data.sh

# 5. Verify.
bash platform/manifests/spicedb/check-permissions.sh
```

Destroys all relationships, schema state, and dispatch caches. Use only on a fresh dev environment or after backing up the DB.
