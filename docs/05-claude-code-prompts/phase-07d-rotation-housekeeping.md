# Phase 7d — Rotation and housekeeping batch

**Status:** ⬜ Not started · ⬜ In progress · ⬜ Complete

**Estimated time:** 1 day

**Prerequisites:** Phase 7 complete (observability stack live; the 90-day BFF rotation cron emits events that need Loki + Alertmanager to surface failure).

---

## Goal of this phase

Two small rotation/housekeeping items that share infrastructure and are cheaper as a batch than as separate phases:

1. **BFF `private_key_jwt` rotation runbook + 90-day cron** (~half day). Phase 6.10b moved the four BFF clients' RSA-2048 signing keypairs into OpenBao at `secret/data/keycloak/clients/<id>` but did not implement rotation. This phase produces the runbook, the rotation script, and the CronJob that drives it.

2. **SpiceDB `datastore_uri` static-copy → database-engine migration** (~half day). Phase 5 follow-up #4. Today `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh` writes the CNPG-managed Postgres URL into `secret/data/spicedb/config` as a *static* value; CNPG password rotation desyncs this. This phase extends OpenBao's database secrets engine (already wired for `helloworld-app` in Phase 5.7) to issue dynamic Postgres creds for SpiceDB, replacing the `VaultStaticSecret` with a `VaultDynamicSecret`.

Each item alone would be too small to justify a phase. Together they share OpenBao, the database secrets engine, and the same verification surface (Phase 5.7's `bao read database/...` paths), making the batch coherent.

---

## What you (the human) need to do first

1. Confirm Phase 7 is complete and Loki/Alertmanager are healthy (the 90-day cron's failure path emits events these consume).
2. Confirm Phase 5.7's database secrets engine is still healthy: `kubectl exec -n openbao openbao-0 -- env BAO_SKIP_VERIFY=1 bao read database/config/postgres-secforge-app` should return a config (not an error). If it doesn't, the Phase 5.7 wiring has rotted and 7d.2 needs that fixed first as a sub-step.
3. Confirm the four BFF clients exist in Keycloak's `secforge-tenants` realm: `helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`. Each should have a public key registered today via Phase 6.10b's bootstrap.
4. Read [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md), specifically the "What we did NOT do" section's `datastore_uri` caveat (lines ~92-97). 7d.2 closes that caveat.
5. Decide whether the kcadm-admin migration (Phase 3 follow-up) has happened by the time you run this phase. If yes, 7d.1's rotation script uses `--client kcadm-admin --secret ...`. If no, it follows the throwaway-service-account pattern from `infrastructure/keycloak/spike-token-exchange.sh` (a per-rotation tmp client). Document the decision in the runbook so a future re-read is unambiguous.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 7d of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md (specifically Phase 5 follow-up #4 and the Phase 7d entry around line 450), docs/02-decisions/0015-secret-distribution-pattern.md, and docs/05-claude-code-prompts/phase-07d-rotation-housekeeping.md before doing anything.

Your task is two separate but co-batched housekeeping items: BFF private_key_jwt rotation (runbook + script + 90-day cron) and SpiceDB datastore_uri migration from static-copy to OpenBao database-engine-issued dynamic creds.

The two are independent — you may sequence them in either order. The recommendation is 7d.1 first (the BFF rotation has more moving parts and is the higher-risk half of the batch) but reverse-order is also fine.

## Phase 7d.1 — BFF private_key_jwt rotation runbook + 90-day cron

Phase 6.10b stored the four BFF clients' RSA-2048 signing keypairs in OpenBao at `secret/data/keycloak/clients/<id>` (where `<id>` is one of `helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`). The BFF reads its private key from OpenBao at startup. Keycloak holds the corresponding public key in the client's JWKS for validating the BFF's `private_key_jwt` client assertions.

Rotation procedure (the runbook codifies this; the script automates it):

1. Generate a new RSA-2048 keypair locally (or in a transient init step inside the script's pod).
2. Register the new public key with Keycloak as an additional JWKS entry for the client. Keycloak supports multiple active public keys per client — the new one becomes available for verification immediately while the old one remains valid for in-flight assertions.
3. Write the new private key to OpenBao at the same path with a new version (KV v2 path: `secret/data/keycloak/clients/<id>` — KV v2 versions automatically; do NOT overwrite without versioning enabled, do NOT delete the old version yet).
4. The BFF picks up the new private key on next session/restart. Phase 6.10b's BFF reads from OpenBao at startup; for an immediate cutover, restart the BFF pod. For a graceful cutover, let pods naturally cycle.
5. After a grace period (recommend 24h — long enough for any in-flight session to complete its DPoP-bound refresh, short enough to limit the window where two keys are valid), deregister the old public key from Keycloak's JWKS for the client.
6. Optionally, after deregistration is verified, delete the old version from OpenBao's KV v2 history (NOT urgent; KV v2 versioning is cheap).

### 7d.1.a — Implement the rotation script

Path: `infrastructure/keycloak/realms/rotate-bff-key.sh`

The script must:

- Accept a client ID as positional argument (one of the four BFF client IDs); refuse anything else.
- Generate a fresh RSA-2048 keypair using `openssl genpkey` (do NOT reuse keys; do NOT generate inside the OpenBao pod — generation belongs to the rotation script context).
- Write the private key as a new KV v2 version at `secret/data/keycloak/clients/<id>`. Use `bao kv put` with the appropriate auth context — match how Phase 6.10b's bootstrap script authenticates.
- Register the new public key with Keycloak. Auth path depends on the kcadm-admin migration state at the time this script runs:
    - If the Phase 3 follow-up (kcadm-admin service-account) has completed: use `kcadm config credentials --client kcadm-admin --secret <fetched-from-openbao>` per the same pattern that follow-up establishes.
    - If not yet completed: follow the throwaway-service-account pattern from `infrastructure/keycloak/spike-token-exchange.sh` — the script creates a tmp service-account client (suggest naming `kcadm-bff-rotate-tmp`), uses it for the JWKS update, then tears it down. Do NOT use `kcadm.sh --user ... --otp ...` — Keycloak 26.x kcadm does not have `--otp` and password+TOTP-concat is brittle.
- The JWKS update mechanic on Keycloak 26.x: a client can have multiple public keys configured via the `jwt.credential.public.key` attribute family OR via a `jwks_url` pointing at a JWKS endpoint OR via `jwks` inline. Phase 6b-0's spike (PLAN.md line 290) found that `jwt.credential.public.key` + `use.jwks.string=false` was misbehaving in 26.x — verify against Phase 7 observability data what the current Phase 6.10b bootstrap actually uses, do NOT assume. The script must match whatever scheme Phase 6.10b set up.
- Emit structured progress logs to STDOUT (`severity=info` shape compatible with the secrets-guardrails event schema if 7b is also deployed; otherwise plain JSON). Promtail picks these up.
- On any error: do NOT swallow. Print to STDERR with non-zero exit code. The CronJob (below) routes failures to Alertmanager.
- Idempotency: re-running mid-flight should be safe. If a new public key has been registered but private key write failed, the next run should detect the orphan public key and clean it up before proceeding.

Test the script manually for `helloworld-bff` BEFORE wiring the cron. Verify a fresh browser login completes end-to-end with the new key. Verify the BFF's pre-rotation key is no longer used (check Keycloak event logs in Loki for `client_assertion` validations; the `kid` should match the new key after restart).

### 7d.1.b — CronJob for 90-day rotation

Schedule a CronJob in the `monitoring` namespace (co-located with other platform crons) that runs the rotation script every 90 days for each of the four BFF clients. Stagger the four schedules across the 90-day window — do NOT rotate all four on the same day, since a same-day rotation magnifies blast radius if there's a regression.

Suggested stagger: helloworld-bff on day 0 of each 90-day window, proposal-forge-bff on day 22, project-tracker-bff on day 45, pm-bff on day 67. Each runs as a separate CronJob with a different `schedule:` cron expression.

The CronJob:

- Runs as a SPIFFE-bound workload (mints a JWT-SVID via spiffe-helper init container; OpenBao role-binding allows it to write to the client paths).
- Mounts the rotate-bff-key.sh script as a ConfigMap.
- Has minimal RBAC (no cluster-wide perms; only the OpenBao policy required for the client paths and Keycloak admin access via the auth path picked above).
- On failure: the script's non-zero exit produces a CronJob failure event, which Phase 7's Alertmanager routes via the existing `Pod CrashLoopBackOff` rule family. If 7b has also deployed, the script should additionally emit a `secrets.guardrail.bypass`-shaped event with `severity=critical` and `rule=bff-key-rotation-failed` so the routing is explicit.

### 7d.1.c — Runbook

Create `docs/03-runbooks/bff-key-rotation.md` covering:

- Overview of the rotation lifecycle (the 6 steps above).
- When to run manually vs. when the cron handles it (ad-hoc rotations after a suspected key compromise; cron handles routine 90-day cadence).
- How to verify a rotation succeeded: structured event log in Loki, a fresh browser login completing, the new `kid` appearing in Keycloak event logs for client_assertion validation.
- How to roll back if a rotation breaks login: restore the previous KV v2 version at `secret/data/keycloak/clients/<id>`, restart the BFF, deregister the new public key from Keycloak (the old one is still registered until step 5 of the procedure, so simply removing the new one returns you to the pre-rotation state).
- The kcadm-admin migration state question: state which auth path the script uses today, and what changes if the Phase 3 follow-up lands.

### 7d.1.d — Verification

Trigger rotation manually for `helloworld-bff`. Verify:

1. New private key version appears at `secret/data/keycloak/clients/helloworld-bff` (`bao kv metadata get` shows the new version number).
2. New public key appears in Keycloak's client config (kcadm `get clients/<id>` or via the admin UI).
3. After BFF pod restart, a fresh browser login completes end-to-end (login at https://app.secforge.local; the BFF's `client_assertion` to Keycloak's token endpoint should validate against the new public key).
4. After the 24h grace period, deregister the old public key. Confirm subsequent logins still work (they should — only the new key is in use after the BFF restart in step 3).
5. Roll back by restoring the previous KV v2 version, re-registering the old public key, restarting the BFF; confirm logins still work. This validates the rollback path before the cron-driven cadence is live.

After manual verification: enable the four CronJobs and let the next scheduled rotation run cron-driven. Verify the cron-driven path produces the same result as the manual path.

## Phase 7d.2 — SpiceDB datastore_uri migration to database-engine

Today's state (per ADR-0015 §"What we did NOT do" and PLAN.md Phase 5 follow-up #4): `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh` writes the CNPG-managed Postgres URL to `secret/data/spicedb/config` as a static value. SpiceDB consumes this via a `VaultStaticSecret` rendered as a K8s Secret, which the SpiceDB Operator's `secretName` references. Problem: when CNPG rotates the postgres password, the static `datastore_uri` desyncs and SpiceDB stops working until someone re-runs the migration script manually.

Target state: OpenBao's database secrets engine (already wired for `helloworld-app` in Phase 5.7) issues dynamic Postgres credentials for SpiceDB on demand. VSO renders a `VaultDynamicSecret` (instead of a `VaultStaticSecret`) into the same K8s Secret name; SpiceDB Operator's `secretName` keeps pointing there; content becomes dynamic. CNPG password rotation no longer breaks SpiceDB because OpenBao re-issues fresh creds on lease expiry.

### 7d.2.a — Verify Phase 5.7 wiring is intact

Before extending the engine for SpiceDB, confirm the existing `helloworld-app` wiring still works:

```
kubectl exec -n openbao openbao-0 -- env BAO_SKIP_VERIFY=1 bao read database/config/postgres-secforge-app
```

Should return a config block (not an error). If it errors with "no such backend mounted" or "Code: 404", Phase 5.7's wiring has rotted and you need to fix that as a prerequisite — out of scope for 7d but DO NOT proceed without resolving it. Document any rot in PLAN.md as a Phase 5 regression.

Also verify the `helloworld-app`'s dynamic creds path is healthy:

```
kubectl exec -n openbao openbao-0 -- env BAO_SKIP_VERIFY=1 bao read database/creds/helloworld-app-readwrite
```

Should return a `username`/`password` pair with a TTL. This is the proven-working pattern that 7d.2.b mirrors for SpiceDB.

### 7d.2.b — Add SpiceDB role to the database engine

Add a database role for SpiceDB mirroring the `helloworld-app-readwrite` shape:

```
bao write database/roles/spicedb-readwrite \
    db_name=postgres-secforge-spicedb \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL ON DATABASE spicedb TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
```

(Verify the actual creation statement against SpiceDB's Postgres permission requirements — SpiceDB needs CREATE/SELECT/INSERT/UPDATE/DELETE on its schema, possibly more for migrations. Cross-check with the existing static `datastore_uri` user's grants by running `\dp` in the spicedb database against the current user.)

The `db_name` (`postgres-secforge-spicedb`) is the OpenBao-side connection config; you'll likely need to register a new connection if the spicedb postgres is a separate CNPG cluster from the helloworld-app one. Use `bao write database/config/postgres-secforge-spicedb ...` mirroring the Phase 5.7 connection config for `postgres-secforge-app`. The connection's root credential should come from CNPG's superuser secret (do NOT hardcode).

Commit the role and connection config as Helm values or a script in `infrastructure/openbao/database-roles/` (new file: `spicedb-readwrite.sh` or equivalent) so the wiring is reproducible from a fresh cluster bootstrap.

### 7d.2.c — Update SpiceDB's VSO binding

Today: `infrastructure/spicedb/06-vso-binding.yaml` has a `VaultStaticSecret` pointing at `secret/data/spicedb/config`. Replace it with a `VaultDynamicSecret`.

The `VaultDynamicSecret`'s `path` field references the database role: `database/creds/spicedb-readwrite`. Its `destination.name` keeps the same K8s Secret name SpiceDB Operator references (verify the current name from the existing `06-vso-binding.yaml`; do NOT rename, that breaks SpiceDB Operator's lookup). Its `destination.transformation` (or VSO's templating equivalent for your VSO version) renders a `datastore_uri` field by string-templating the issued `username` and `password` into the postgres connection URL — match the URL shape the static value used today.

Refresh interval: the `VaultDynamicSecret` should re-issue creds before the role's `default_ttl` (1h) expires. Suggest `refreshAfter: 30m` or use VSO's lease-aware mode (`renewalPercent` or equivalent) so re-issue happens at 50% of lease lifetime. Verify against your VSO version's actual API — VSO's dynamic-secret rotation semantics have evolved across releases.

The `VaultAuth` reference stays the same (the spicedb namespace's existing K8s SA → OpenBao role binding from Phase 6.10b). Verify the OpenBao policy bound to that role allows reading from `database/creds/spicedb-readwrite` — likely the existing policy only allows `secret/data/spicedb/*`, so you'll need to extend it.

Update the OpenBao policy at `infrastructure/openbao/policies/<spicedb-policy>.hcl` (find the actual name via `bao policy list`) to add a rule:

```
path "database/creds/spicedb-readwrite" {
    capabilities = ["read"]
}
```

### 7d.2.d — Update SpiceDB Operator config if needed

Most SpiceDB Operator configs reference the secret by name and read fields by key. If the `VaultDynamicSecret`'s rendered fields match the `VaultStaticSecret`'s rendered fields one-for-one (same key names), no SpiceDB Operator config change is needed.

Check `infrastructure/spicedb/05-spicedb-cluster.yaml` (or wherever the SpiceDBCluster CR lives) for `secretName` and the field references. Verify post-cutover that all referenced fields are still populated.

### 7d.2.e — Force a CNPG password rotation as the smoke test

This is the test the static-copy approach fails. With the dynamic engine in place:

1. Run `infrastructure/spicedb/check-permissions.sh` once and confirm it passes (pre-rotation baseline).
2. Force a CNPG password rotation: `kubectl cnpg promote ...` or however the CNPG operator exposes credential rotation in your install — verify against `kubectl explain cluster.spec.bootstrap` for the actual mechanic. (CNPG-side credential rotation is not under VSO's control; whatever path you take is fine as long as it produces a new password on the postgres side.)
3. Wait for the next VSO refresh cycle (≤ refreshAfter interval; up to 30 min if you suggested that).
4. Run `infrastructure/spicedb/check-permissions.sh` again. Should still pass — without manual intervention.

If step 4 fails, the dynamic engine's rotation isn't actually picking up the new postgres-side state. Likely culprits: the OpenBao connection config still has the old root cred (re-update via `bao write database/config/postgres-secforge-spicedb root_credentials_ttl=...`) or VSO isn't refreshing on the cadence you set. Diagnose via OpenBao's audit log (Phase 7 should be ingesting it) and VSO's controller logs.

### 7d.2.f — Decommission the static migration script

Once the dynamic path is verified, delete `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh` (or move to `infrastructure/vault-secrets-operator/archive/` with a comment noting "superseded by Phase 7d database-engine wiring; retained for audit"). The script is now dead code — leaving it live invites someone to re-run it and clobber the dynamic path with a static value.

Also delete the static `secret/data/spicedb/config` path from OpenBao once you're confident nothing else reads it: `bao kv delete secret/data/spicedb/config` (KV v2 versioning means the data is recoverable from history if needed). Run a `grep` across the repo for `secret/data/spicedb/config` first to make sure no consumer still references it; the AuthZEN façade's binding is a separate path (`secret/data/spicedb/preshared-key`) and is unaffected.

### 7d.2.g — Update ADR-0015

Update [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md) §"What we did NOT do": the `OpenBao database secrets engine for SpiceDB` caveat is now resolved. Either delete that bullet entirely or update to "Resolved Phase 7d (date)" with a reference to the dynamic-engine wiring committed in this phase.

Also update PLAN.md Phase 5 follow-up #4: mark resolved, with a reference to Phase 7d's commit.

## Phase 7d.3 — Documentation

Update:

- `docs/03-runbooks/bff-key-rotation.md` (new, from 7d.1.c)
- `docs/03-runbooks/spicedb-operations.md`: replace the static `datastore_uri` notes with the dynamic-creds story; document the OpenBao role and how to revoke a leased credential if compromised
- `docs/01-architecture/05-secrets-management.md`: update the SpiceDB row in the secrets distribution table from "VSO static" to "VSO dynamic via database engine"
- ADR-0015 (per 7d.2.g)
- PLAN.md: mark Phase 7d ✅; update Phase 5 follow-up #4 status

## Constraints

- Do NOT introduce new tools beyond what PLAN.md and CLAUDE.md commit to.
- Do NOT use `kcadm.sh --otp` anywhere (Keycloak 26.x kcadm has no --otp flag — see PLAN.md Phase 3 follow-up). Pick the appropriate auth path per the kcadm-admin migration state.
- Do NOT hardcode Postgres root credentials in any committed manifest. CNPG's superuser secret is the source.
- Do NOT delete the old static `datastore_uri` value from OpenBao until 7d.2.e verifies the dynamic path actually works through a CNPG rotation cycle.
- Do NOT commit the rotation script with the BFF key-generation step running inline at apply time (e.g., as a Helm hook) — keypair generation belongs to the script's runtime context, not the static manifest.
- Verify against Phase 7 observability data wherever this prompt says to verify against actual cluster behavior — do NOT trust the prompt's assumptions over what the cluster is actually doing today.
```

---

## Success criteria

- [ ] `infrastructure/keycloak/realms/rotate-bff-key.sh` committed; manual rotation of `helloworld-bff` succeeds end-to-end (browser login passes post-rotation)
- [ ] Four CronJobs (one per BFF client) committed and enabled, staggered across the 90-day window
- [ ] `docs/03-runbooks/bff-key-rotation.md` committed; covers manual + cron paths and the rollback procedure
- [ ] OpenBao database role `spicedb-readwrite` committed and verifiable via `bao read database/creds/spicedb-readwrite`
- [ ] OpenBao policy for SpiceDB extended to allow reading `database/creds/spicedb-readwrite`
- [ ] `infrastructure/spicedb/06-vso-binding.yaml` updated to `VaultDynamicSecret`; rendered K8s Secret content matches what SpiceDB Operator expects
- [ ] CNPG password rotation smoke test: `infrastructure/spicedb/check-permissions.sh` passes both pre- and post-rotation without manual intervention
- [ ] Static `datastore_uri` migration script archived/deleted; static OpenBao path cleaned up
- [ ] ADR-0015 §"What we did NOT do" updated; PLAN.md Phase 5 follow-up #4 marked resolved
- [ ] PLAN.md Phase 7d marked ✅

---

## Troubleshooting

### "BFF rotation script registers the new public key but BFF still uses the old private key"

The BFF reads OpenBao at startup (per Phase 6.10b). Either the BFF wasn't restarted after the new private key was written, or the BFF's read path is hitting a stale KV v2 version (e.g., it pinned `version=N`). Verify the BFF's OpenBao read does NOT pin a version — it should fetch latest. If it does pin: that's a Phase 6.10b bug to file separately.

### "After rotation, login fails with `invalid_client: Unable to load public key`"

You're hitting the Phase 6b-0 finding (PLAN.md line 290): `jwt.credential.public.key` + `use.jwks.string=false` format changed in Keycloak 26.x. Verify the rotation script is using the same JWKS configuration scheme that Phase 6.10b's bootstrap used today. If the bootstrap script uses a different attribute family than the rotation script, the public key won't be found by Keycloak's validator.

### "VaultDynamicSecret renders empty fields"

VSO needs the `VaultAuth` resource's SA to have OpenBao role-binding that includes the `database/creds/spicedb-readwrite` path in its policy. Check `bao read auth/kubernetes/role/<role-name>` and confirm the policy listed there permits the path. Also confirm the SA's namespace matches what the role expects — VSO's K8s auth is namespace-scoped (per ADR-0015 lesson #2).

### "CNPG rotation smoke test: SpiceDB still sees stale credentials"

VSO's refresh cycle hasn't fired yet, OR VSO is using lease-aware mode but SpiceDB is holding open a connection past the lease. SpiceDB-side: many DB-using services pool connections; old connections survive credential rotation until they're closed naturally. Check SpiceDB's connection-recycle config; consider a periodic restart if the pool holds connections indefinitely. This is a SpiceDB-side concern, not an OpenBao or VSO bug.

### "I forgot which auth path the rotation script uses"

Read the runbook at `docs/03-runbooks/bff-key-rotation.md` — that's exactly what the runbook documents (per 7d.1.c, the auth-path-question section). If the runbook is out of date, update it; the runbook is the source of truth for "what does this rotation actually do today."

---

## What's next

[Phase 8 — Privileged Access (Teleport, optional)](./phase-08-teleport.md). If skipping, jump to [Phase 9](./phase-09-hello-world.md). 7c and 7d are independent of each other; if you ran 7d first, [Phase 7c — Istio SPIRE-as-CA cutover + STRICT](./phase-07c-istio-spire-ca-and-strict.md) is the other half of the post-Phase-7 work.
