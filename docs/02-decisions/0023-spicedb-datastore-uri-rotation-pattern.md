# ADR-0023: SpiceDB `datastore_uri` rotation pattern — CronJob-refreshed VaultStaticSecret over native VaultDynamicSecret

**Status**: Amended 2026-05-03 (TTL bug fix — see § Amendment 2026-05-03)
**Date**: 2026-05-02
**Decision-makers**: Project owner
**Phase**: 7d.2

## Context

[ADR-0015 §"What we did NOT do"](./0015-secret-distribution-pattern.md) flagged a known caveat: SpiceDB's Postgres `datastore_uri` was migrated into OpenBao at `secret/data/spicedb/config` as a **static** copy of the CNPG-managed Postgres connection string (per `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh`). CNPG password rotation desyncs the static value, requiring manual re-run of the migration script. Phase 7d.2 was scoped to close this caveat by replacing the `VaultStaticSecret` with a `VaultDynamicSecret` rendering credentials issued by OpenBao's database secrets engine — analogous to the existing wiring for `helloworld-app` (Phase 5.7).

That plan hit a structural blocker the original prompt didn't anticipate.

### What's in `spicedb-config-vso` today

The K8s Secret named by `SpiceDBCluster.spec.secretName` contains **two** keys:

| Key | Source | Purpose |
|---|---|---|
| `preshared_key` | `secret/data/spicedb/config` (static; original PSK from `apply.sh`) | gRPC pre-shared-key for SpiceDB clients (AuthZEN, future apps) |
| `datastore_uri` | `secret/data/spicedb/config` (static; CNPG-issued connection string) | Postgres connection URI for SpiceDB's datastore |

Both keys are read by SpiceDB Operator from the **same** Secret. The operator does not support pulling them from separate sources.

### What VSO supports

VSO 0.7+ offers two relevant CRDs:

- **`VaultStaticSecret`** — renders one OpenBao KV-v2 path into one K8s Secret. `data.<key>` → `Secret.data.<key>` 1:1. Refresh on a polling cadence (`refreshAfter`) or when the underlying KV version bumps.

- **`VaultDynamicSecret`** — issues a dynamic credential against an OpenBao secrets engine (database, AWS, etc.), renders the issued credential into a K8s Secret. The Secret's keys are the dynamic-cred fields (`username`, `password`, `_raw`) plus optional templated keys produced by `destination.transformation`.

Crucially: a single VSO resource — Static or Dynamic — renders from **one** OpenBao source. There is no native VSO mechanism to compose a single K8s Secret from `secret/data/<X>` + `database/creds/<Y>`. The transformation block can compute new keys from the source's data, but cannot pull from a second source.

### The structural blocker

Replacing the existing `VaultStaticSecret` with a `VaultDynamicSecret` against `database/creds/spicedb-readwrite` produces a Secret with `username`+`password`+`_raw` (and optionally a templated `datastore_uri`). The PSK is **lost** — VSO has no way to merge it in.

Three approaches were considered, all with material costs:

#### (A) Two VSO resources + custom merge controller

Render PSK via `VaultStaticSecret` → Secret X. Render datastore_uri via `VaultDynamicSecret` → Secret Y. Add a controller (CronJob or custom controller) that watches both and writes the merged `spicedb-config-vso` Secret. **Cost**: net-new infrastructure (the merge controller). No operational payoff over (B); both run a CronJob and the merge logic is the bulk of either's complexity.

#### (B) CronJob-refreshed `VaultStaticSecret` (chosen)

Keep the existing `VaultStaticSecret` pointed at `secret/data/spicedb/config`. Add a CronJob that, on a cadence below the dynamic-cred max_ttl, mints a fresh credential from `database/creds/spicedb-readwrite`, combines it with the still-static PSK, and writes a new KV-v2 version at `secret/data/spicedb/config`. VSO refreshes from the bumped KV version → SpiceDB Operator's `secretName` watch fires → SpiceDB pod rolls with new creds. **Cost**: one CronJob, zero changes to SpiceDB Operator integration, zero new controllers.

#### (C) Restructure SpiceDB Operator integration

Change `SpiceDBCluster.spec.secretName` to point at the dynamic-only Secret. Inject `preshared_key` separately via Deployment patches (`envFrom` or `env.valueFrom.secretKeyRef`) on a per-version basis. **Cost**: touches the SpiceDB Operator CR shape, which couples our config to SpiceDB Operator's version-specific behavior. Future operator upgrades may move the secret-key plumbing in ways we'd have to track. The "merged secret" pattern is what the operator's docs assume; deviating creates upgrade-time surprise risk for a critical-path component.

## Decision

**Adopt (B): CronJob-refreshed `VaultStaticSecret`.**

1. **Keep** the existing `VaultStaticSecret` at `infrastructure/spicedb/06-vso-binding.yaml` pointing at `secret/data/spicedb/config`. Refresh interval unchanged.

2. **Add** an OpenBao database-engine connection (`database/config/secforge-spicedb`) and role (`database/roles/spicedb-readwrite`), bootstrapped by `infrastructure/openbao/database-roles/spicedb-readwrite.sh`. Pattern mirrors Phase 5.7's `helloworld-app-readwrite` setup, with the role's `creation_statements` using Postgres role membership (`GRANT spicedb TO "{{name}}"; … INHERIT;`) so dynamic users inherit the schema-owner's privileges (covers DML at runtime AND ALTER for schema migrations, without explicit per-object grants).

3. **Add** a 12-hourly CronJob (`spicedb-datastore-refresher` in the `spicedb` namespace) that:
   - Mints a fresh credential from `database/creds/spicedb-readwrite` (OpenBao revokes the previous lease; new TTL 1h, max 24h).
   - Reads the current `preshared_key` from `secret/data/spicedb/preshared-key` (the AuthZEN-shared static PSK path; PSK rotation is out of scope for this ADR).
   - Writes a new KV-v2 version at `secret/data/spicedb/config` containing `preshared_key` (unchanged) + `datastore_uri` (templated from the new dynamic cred).

4. **Cadence**: 12h, below the dynamic-cred `max_ttl` of 24h. This gives a 12-hour overlap window during which both the OLD lease (still valid) and the NEW lease (just issued) are alive on the Postgres side, so any in-flight SpiceDB pod that hasn't yet picked up the rendered K8s Secret update is not authentication-broken.

5. **VSO refresh + SpiceDB rollout**: `VaultStaticSecret.spec.refreshAfter: 60s` (existing setting; no change). When VSO sees a new KV version, it updates the K8s Secret content; SpiceDB Operator's `secretName` watch fires; the operator triggers a Deployment rollout. SpiceDB pod restarts with the new creds. Net effect: ~one SpiceDB pod restart per 12h.

This pattern is **local-edition specific**. Cloud-edition migration should revisit if SpiceDB Operator gains multi-source secret support (e.g., a future `secretRef` slice) or if a clean-room single-Secret merge becomes available via VSO. Until then, the same blocker would surface in cloud as well, and (B)'s CronJob is just as portable as the underlying VSO + KV pattern.

## Rationale

### Why not (A) — two VSO + merge controller

The merge controller would be a new long-running deployment with its own image, RBAC, and supply-chain footprint. The CronJob in (B) is a sub-minute alpine/k8s pod that runs every 12h — no persistent attack surface, no upgrade dependency, no monitoring ramp. The complexity of the merge logic is identical (read two sources, write one Secret); putting it on a cron eliminates the cost of running it continuously.

### Why not (C) — patch SpiceDB Operator integration

SpiceDB Operator's `secretName` semantics are documented and stable as a single-merged-Secret contract. Patches that work around this contract (envFrom on a separate Secret) implicitly rely on the operator's pod-template generation NOT shadowing or merging the patch in unexpected ways across version bumps. SpiceDB is a critical-path component for every authorization decision in the platform; coupling its config to operator-internal patch behavior is exactly the kind of upgrade-time fragility we don't want to inherit.

### Why CronJob over a true `VaultDynamicSecret`

If SpiceDB Operator could read PSK and datastore_uri from separate Secrets, we'd use `VaultDynamicSecret` directly — one less moving part. The CronJob exists **only** to bridge the structural gap between VSO's single-source model and the operator's single-Secret-with-merged-keys contract. The CronJob is morally equivalent to "what `VaultDynamicSecret` would do, if it could compose with another source."

### Why 12h cadence

Dynamic-cred default_ttl is 1h; max_ttl is 24h. VSO renders the rendered Secret with the issued cred until max_ttl, then re-issues. The CronJob must run faster than max_ttl to ensure the K8s Secret is refreshed before SpiceDB's connections start failing on lease-expired creds.

12h gives:
- A new credential mint at hours 0, 12, 24, 36, …
- Each cred valid for max 24h on the Postgres side.
- At the 12h refresh, the OLD cred has 12h life remaining (alive); the NEW cred is freshly minted with a fresh 24h max_ttl.
- SpiceDB pod rolls on the K8s Secret update; the rollout takes <2min in practice. Even on a stuck rollout, the OLD cred has 12h to keep things alive.

A 6h cadence would be safer but doubles the SpiceDB rollout rate. 12h is the operational sweet spot for local edition; cloud can revisit.

### Why not just longer max_ttl + slower CronJob

Dynamic-cred lifetime longer than ~24h erodes the security benefit of dynamic creds (the whole point is short-lived). 24h is the helloworld-app-readwrite precedent ([Phase 5.7 configure-engines.sh](../../infrastructure/openbao/configure-engines.sh)) — staying consistent reduces the operator's mental model variance.

### CNPG password rotation safety

The original ADR-0015 caveat was that CNPG password rotation desyncs the static `datastore_uri`. With this pattern:

1. CNPG rotates the postgres password for `spicedb`.
2. OpenBao's `database/config/secforge-spicedb` still has the OLD password (the connection's "root credential" is OpenBao's, not CNPG's, after `rotate-root`).
3. The next CronJob run mints a credential — and OpenBao authenticates as its OLD password to Postgres, which now FAILS (because Postgres has the NEW password).

→ **CNPG-side password rotation breaks the rotator**. The cluster's CNPG operator does NOT independently rotate; passwords drift only via explicit operator action. This was the same risk as helloworld-app-readwrite (which suffered exactly this rot — see [PLAN.md operator-backlog #16](../../PLAN.md)).

**Mitigation:** the cluster's CNPG password is stable across the cluster's lifetime unless an operator explicitly rotates it. Rotation procedures must include a step to re-bootstrap the OpenBao connection's root credential (psql peer-auth + `bao write database/config/...` + `bao write -force database/rotate-root/...`). Documented in the SpiceDB rotation runbook (Phase 7d.3).

This is a meaningful caveat: the OpenBao database engine assumes static root credentials at the postgres level. CNPG's emergent rotation behavior (from version upgrades, manual operator action, or recovery procedures) requires a known-procedure response. It is NOT silently auto-handled. Cloud-edition should consider RDS IAM auth or similar to remove this coupling.

## Consequences

### Operational

- **One additional CronJob** in the `spicedb` namespace, running every 12h. Resource footprint: ~50m CPU, 64Mi memory per run, lasting <30s.

- **SpiceDB pod restarts** on every CronJob run that produces a different rendered Secret (i.e., every run, since each run mints a new credential). Local-edition impact: brief grpc connection churn on the AuthZEN façade and other consumers; no user-visible auth flow disruption (AuthZEN's CheckPermission calls retry naturally).

- **Operator-backlog #16** (Phase 5.7 `secforge-app` DB engine root-cred drift) should be fixed using the same recipe documented for the spicedb side. The two are independent regressions.

### Security

- **Dynamic-cred semantic preserved.** Each SpiceDB pod runs with a fresh Postgres user that's a member of the `spicedb` role for the duration of its lifetime. The prior single-static-credential model meant compromise of the SpiceDB pod = compromise of the static datastore credential, with no expiry.

- **Defense-in-depth unchanged.** ADR-0015's split between AuthZEN's policy (`secret/data/spicedb/preshared-key` only — no Postgres password) and SpiceDB's policy (full config) remains in force. The new `vso-spicedb-db.hcl` policy (added Phase 7d.2) extends `spicedb-vso`'s capabilities to read `database/creds/spicedb-readwrite` ONLY for the rotator CronJob, not for any other VSO consumer.

- **Net new attack surface = the CronJob.** It runs as SPIFFE-bound, RBAC-scoped, no-internet egress. Its failure mode is "stale rendered Secret"; manifest as eventual SpiceDB DB-auth failure once the lease expires. Detected by the existing kube-state-metrics `KubeJobFailed` rule (already wired by Phase 7).

### Future work

- **Cloud-edition revisit.** When porting to cloud, evaluate:
  - SpiceDB Operator versions that may support multi-secret bindings.
  - Cloud-native IAM auth (RDS IAM, GCP Cloud SQL IAM) that obviates the OpenBao database engine entirely for managed Postgres.
  - VSO + ESO (External Secrets Operator) hybrid with a custom merger CRD if the upstream ecosystem produces one.

- **Same pattern applies to other "merged-secret" consumers** if any future component holds the same shape (one secretName, multiple keys from different sources). Document the pattern once in the SpiceDB runbook; reference from there.

## What we did NOT do

- **Did NOT switch SpiceDB Operator integration.** `secretName` semantics preserved; this is the load-bearing reason cloud-migration is not blocked by this decision.

- **Did NOT introduce a custom merge controller.** The CronJob covers the same ground without a long-running reconciler.

- **Did NOT modify ADR-0015.** That ADR's broader VSO/direct-API split remains intact; this ADR is a narrow extension addressing the specific multi-source-merge gap that surfaced when 7d.2 tried to close ADR-0015's `datastore_uri` caveat. The ADR-0015 caveat is now resolved at the consumer level (the Secret SpiceDB sees is fresh), even though the underlying mechanism is "static path with periodic refresh" rather than "dynamic path."

## References

- [ADR-0015 — Secret distribution pattern (VSO vs direct-API)](./0015-secret-distribution-pattern.md) — the broader split this extends.
- [Phase 5.7 `infrastructure/openbao/configure-engines.sh`](../../infrastructure/openbao/configure-engines.sh) — the helloworld-app-readwrite dynamic-cred pattern this mirrors.
- [Phase 6.10b `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh`](../../infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh) — the original static migration; decommissioned by Phase 7d.2.f.
- [`infrastructure/spicedb/06-vso-binding.yaml`](../../infrastructure/spicedb/06-vso-binding.yaml) — the VaultStaticSecret manifest (unchanged by this ADR).
- [`infrastructure/openbao/database-roles/spicedb-readwrite.sh`](../../infrastructure/openbao/database-roles/spicedb-readwrite.sh) — the database-engine bootstrap (Phase 7d.2.b).
- [`infrastructure/spicedb/cron/spicedb-datastore-refresher.yaml`](../../infrastructure/spicedb/cron/spicedb-datastore-refresher.yaml) — the 12h refresher CronJob (Phase 7d.2.c).
- [`docs/03-runbooks/spicedb-operations.md`](../03-runbooks/spicedb-operations.md) — operational runbook including CNPG-rotation recovery procedure.

---

## Amendment 2026-05-03 — TTL bug fix

The original Decision § "Why 12h cadence" claimed a 12-hour overlap between consecutive refreshes:

> 12h gives:
> - A new credential mint at hours 0, 12, 24, 36, …
> - **Each cred valid for max 24h on the Postgres side.**
> - At the 12h refresh, **the OLD cred has 12h life remaining (alive)**; the NEW cred is freshly minted with a fresh 24h max_ttl.

**This was wrong.** It misread OpenBao's lease semantics.

`default_ttl` is the **initial** lease length when a credential is minted; `max_ttl` is the maximum the lease can be **extended to via explicit renewal** (`bao lease renew <lease-id>`). It is NOT the credential's default lifetime. Without an explicit renewal call, a credential lives only `default_ttl` and is then revoked.

Nothing in the SpiceDB stack renews leases:
- The refresher CronJob mints NEW credentials every 12h but does not touch existing leases.
- SpiceDB's Postgres connection pool caches the password from pod startup; it never re-fetches from the K8s Secret nor calls OpenBao's renewal API.
- VSO's `VaultStaticSecret` polls KV-version changes; it has no role in lease management.

So with the original `default_ttl=1h, max_ttl=24h`:
- Refresher mints credential at T0 → 1h lease
- T0+1h → OpenBao revokes the Postgres role (revocation_statements run)
- T0+1h to T0+12h → SpiceDB's existing connections may keep working (Postgres doesn't kill on user drop), but every new connection (e.g., from a `readyz` probe, idle reconnect, or pool growth) fails SASL → SpiceDB crashloop → AuthZEN-facade crashloop downstream
- T0+12h → next refresh runs, K8s Secret bumps, SpiceDB rolls, cycle restarts

**Empirical confirmation 2026-05-03:** the cluster wedged twice in one debug session, both times with `failed SASL auth: FATAL: password authentication failed for user "v-jwt-spif-spicedb--..."` exactly because the lease had expired between cron runs. Each recovery required manually triggering a `--from=cronjob/spicedb-datastore-refresher` job and bouncing the SpiceDB pod.

**Fix:** change the role's `default_ttl` from `1h` to `14h` (12h cron interval + 2h overlap margin). Keep `max_ttl=24h` unchanged for headroom in case any future component starts renewing.

This restores the original Decision's intended overlap semantics — the OLD credential stays alive for 2h after the new one is minted and SpiceDB rolls. Connections established pre-refresh continue working until they're closed normally; new connections post-refresh use the new credential.

| | Before | After |
|---|---|---|
| `default_ttl` | `1h` | **`14h`** |
| `max_ttl` | `24h` | `24h` (unchanged) |
| Overlap window | -11h (broken 11h every cycle) | +2h |
| Cluster healthy 24h/day? | No (failed every cycle) | Yes |

### Implications for helloworld-app-readwrite (Phase 9)

`infrastructure/openbao/configure-engines.sh` configures `helloworld-app-readwrite` with the same `default_ttl=1h, max_ttl=24h`. **That is correct for helloworld-app** because helloworld-app is a first-class app that fetches credentials via `apps/lib/secrets/` at request time and gets fresh values when leases expire — no static-cache-in-pod problem. SpiceDB cannot do that (off-the-shelf workload, K8s-Secret-only consumer).

The bug applies specifically to consumers whose architecture is "read K8s Secret at startup, hold the value for the pod's lifetime." Future consumers of that shape need the same `default_ttl ≥ refresh_cron_interval + margin` rule. Direct-API consumers using `apps/lib/secrets/` keep `default_ttl=1h` for tighter dynamic-cred semantics.

### What changed in this commit

- `infrastructure/openbao/database-roles/spicedb-readwrite.sh` — `default_ttl=1h` → `default_ttl=14h`. Comment block expanded to explain the lease semantics + why this consumer differs from helloworld-app-readwrite.
- This ADR — Status: Amended; this Amendment section.
- `docs/03-runbooks/spicedb-operations.md` — corrected the "max_ttl 24h" framing of the rotation cadence.

To apply on a running cluster: re-run the bootstrap script with an admin BAO_TOKEN. The script's `bao write database/roles/spicedb-readwrite ...` is idempotent — it overwrites the existing role with the new TTLs. Existing leases are NOT affected; they continue running their old TTL and will be revoked at expiry. The next refresher run mints a credential with the new 14h TTL and the cluster reaches steady state from that point forward.
