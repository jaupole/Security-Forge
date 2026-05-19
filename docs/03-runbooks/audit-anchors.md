# Audit-log hardening (operator-backlog #33)

Hash-chained audit logs, signed Ed25519 anchors committed to a public
GitHub repo, continuous verifier worker, SpiceDB-gated read.

## Architecture in one paragraph

Every app's `audit.event` table has a `(prev_hash, full_hash)` sha256
chain anchored to a zero-byte sentinel. `lib/audit.ts` writes new rows
under `pg_advisory_xact_lock`. A `audit-verifier` CronJob runs every
5 min, walks the chain, and flips `audit.tamper_flag.tamper_detected`
on mismatch (which `record()` honours — refuses new writes until an
operator clears the flag). A nightly `audit-anchor` CronJob signs the
latest `full_hash` with OpenBao Transit Ed25519 (`transit/keys/audit-signing`)
and commits a JSON anchor to <https://github.com/jaupole/secforge-audit-anchors>.
Read paths are gated by the SpiceDB `read_audit` permission
(`auditor` relation + cascading admin).

## One-time setup per app

1. **OpenBao Transit key** — done once cluster-wide:
   ```bash
   bao write -f transit/keys/audit-signing type=ed25519 exportable=false
   bao policy write audit-signer - <<EOF
   path "transit/sign/audit-signing"   { capabilities = ["create","update"] }
   path "transit/sign/audit-signing/*" { capabilities = ["create","update"] }
   path "transit/keys/audit-signing"   { capabilities = ["read"] }
   EOF
   ```

2. **Per-app k8s-auth role** (one per app):
   ```bash
   bao write auth/kubernetes/role/<app>-audit-signer \
     bound_service_account_names=<app>-audit-signer \
     bound_service_account_namespaces=<app> \
     token_policies=audit-signer \
     token_ttl=15m token_max_ttl=30m
   ```

3. **GitHub PAT for `jaupole/secforge-audit-anchors`** — operator-side:
   - Settings → Developer settings → Fine-grained PAT
   - Resource owner: jaupole. Repository: only `secforge-audit-anchors`.
   - Repository permissions: **Contents: Read and write**. Expiration: 90d.
   - Write to OpenBao:
     ```bash
     bao kv put secret/apps/<app>/audit-anchors-push-token token=<paste>
     ```
   - The per-app VSO binding (in `12-audit-anchor-cronjob.yaml`) renders
     this into a K8s Secret `audit-anchors-push-token` in the app ns.

   > **STATUS 2026-05-19**: the GitHub PAT ("SecForge Audit Anchors",
   > fine-grained, Contents:RW on `secforge-audit-anchors`, expires
   > 2027-05-19) is **already created and already stored in OpenBao** at
   > `secret/apps/member-hub/audit-anchors-push-token`. It is **untouched
   > — never run against** anything: the audit-anchor CronJob only fires
   > once Member Hub is deployed to the cluster (currently laptop-hybrid-
   > dev, no cluster footprint — see operator-backlog #34's
   > Member-Hub-Track-C note). **FIX-WHEN-WE-MOVE-MEMBER-HUB**: when
   > Member Hub gets its cluster deployment, (a) confirm this token still
   > has >30d to expiry, (b) confirm the VSO binding renders the
   > `audit-anchors-push-token` Secret, (c) confirm the
   > `audit-verifier-db` password Secret is populated (Step 4 below),
   > then apply manifests 12 + 13. Until then nothing here is live.

4. **CNPG `audit_verifier` role password** — needs a one-off SQL after
   migration 040 applies + write password to OpenBao:
   ```sql
   -- as the cluster owner
   ALTER ROLE audit_verifier WITH PASSWORD '<random-32-byte>';
   ```
   ```bash
   bao kv put secret/apps/<app>/audit-verifier-db password=<random-32-byte>
   ```

5. **Apply manifests** — `kubectl apply -k platform/manifests/<app>/`.
   The CronJobs schedule themselves; first anchor lands at 00:17 UTC.

## Day-to-day operations

### Anchor commit cadence

- **Schedule**: 00:17 UTC daily.
- **Skip-and-resume**: a missed run picks up from the last anchor's
  `covers_through_id` on the next successful run. No data loss; an
  anchor's `date` is the signing date, not the rows-covered date.
- **Idempotency**: re-running on the same day with no new audit rows
  exits 0 with `no new rows since previous anchor` and commits nothing.

### When the verifier flags tamper

1. CronJob output (`kubectl logs`) shows
   `{"status":"tamper_detected","first_bad_id":<n>,...}`.
2. Application writes start failing with
   `audit: tamper flag set; refusing to write new chain rows`.
3. **Investigate** — query `audit.tamper_flag` for the `first_bad_id`,
   then look at rows around it. Compare against the last public anchor
   in `secforge-audit-anchors/<app>/<date>.json` to bound the
   tampering window.
4. **Decide on remediation** — typical options:
   - Restore the audit table from the pre-tamper backup (most common
     for accidental tampering during migration testing).
   - Accept the chain break + log the incident as a separate
     `audit.tamper_flag.cleared` event (when the tampering is known
     and limited).
5. **Clear the flag**:
   ```bash
   pnpm tsx src/scripts/clear-audit-tamper-flag.ts --confirm \
     --by-user-id <your-keycloak-sub>
   ```
   Writes a `audit.tamper_flag.cleared` event that becomes the start
   of the next chain segment. Future anchors only need to verify from
   this row forward.

### Verifying an anchor externally

`secforge-audit-anchors/scripts/verify.py` (TBD) takes:
- the JSON anchor file
- a SQL dump of `audit.event` for the rows it covers
- the OpenBao Transit public key

and recomputes the chain + verifies the Ed25519 signature. Anyone with
GitHub access can run this — the audit anchors are public.

## Rolling out to a new app (Proposal Forge / Project Tracker / etc.)

1. Mirror the migrations from `Member Hub/migrations/039_audit_hash_chain.sql`
   + `040_audit_tamper_flag.sql`. Replace `member_hub_app` role names with
   the new app's role.
2. Mirror `Member Hub/src/lib/audit.ts` + `workers/audit-verifier/verify.ts`
   + `src/scripts/clear-audit-tamper-flag.ts`.
3. Add `auditor` relation grant in Ecosystem Control's UI (or seed it
   via the role catalog) for compliance users.
4. Mirror `platform/manifests/member-hub/12-audit-anchor-cronjob.yaml`
   + `13-audit-verifier-cronjob.yaml`, search-and-replace
   `member-hub` → `<new-app>`.
5. Run the One-time setup steps above for the new app (k8s-auth role
   per app; the Transit key is shared; the audit-verifier-db Secret
   is per-app).
6. First anchor commit appears in
   `secforge-audit-anchors/<new-app>/<date>.json` the next 00:17 UTC.

## Why public anchors

Public verifiability is the threat model. Three independent
compromises are needed to forge an undetected tamper:
1. DB superuser to mutate rows.
2. OpenBao Transit private key to forge the signature.
3. Force-push to `secforge-audit-anchors` to overwrite history
   (visible in the GitHub Releases feed + to any watcher).

A regulator, tenant, partner, or you-three-years-from-now can clone
the public anchors repo, dump an app's audit log, and verify
end-to-end without access to any SecForge infra.

## References

- operator-backlog #33 (the open ticket that drove this work)
- `Member Hub/.claude/skills/audit-logging/SKILL.md` (the original spec)
- `Member Hub/migrations/039_audit_hash_chain.sql` (DDL)
- `Member Hub/migrations/040_audit_tamper_flag.sql` (verifier surface)
- `Member Hub/src/lib/audit.ts` (chain-on-insert)
- `Member Hub/workers/audit-verifier/verify.ts` (continuous verify)
- `Member Hub/src/scripts/clear-audit-tamper-flag.ts` (operator escape hatch)
- `infrastructure/spicedb/ecosystem-schema.zed` (`auditor` + `read_audit`)
- `platform/manifests/member-hub/12-audit-anchor-cronjob.yaml` (signer)
- `platform/manifests/member-hub/13-audit-verifier-cronjob.yaml` (verifier)
- <https://github.com/jaupole/secforge-audit-anchors>
