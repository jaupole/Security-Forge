# Per-org Transit key rotation

Operator runbook for rotating an organization's `pii-org-<orgId>`
Transit key + (optionally) re-wrapping its existing ciphertext onto
the new version. Pairs with [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md)
and the per-tenant-key work in Ecosystem Control commits `8815eb9` +
`9656f80`.

## When to rotate

Trigger a rotation in any of:

1. **Key compromise.** Concrete signal that the key material may have
   leaked (Transit cipher exfil, OpenBao admin token leak, an operator
   `bao kv get` console screenshot, etc.) — rotate **immediately**
   followed by a mandatory rewrap pass.
2. **Vendor-credential rotation.** When an org rotates its underlying
   Stripe secret key / QBO refresh token / Postmark server token via
   the admin UI, the new ciphertext goes onto the latest key version
   automatically. No separate Transit rotation is required for this
   case — the credential rotation IS the rotation.
3. **Periodic policy.** Industry guidance for application-layer
   envelope-encryption keys is **12-24 months**. We don't enforce a
   schedule today; an operator should run the bulk rotation script
   (below) annually unless audit/compliance pushes for tighter.
4. **Operator-departure / breach response.** Same as compromise but
   driven by personnel change rather than confirmed leak. Rotate the
   keys for orgs the departed operator had access to.

## What rotation does

OpenBao Transit keeps multiple versions of each key. `rotate` bumps
the version counter:

- Pre-rotation ciphertext (`vault:v1:…`) stays decryptable against
  the OLD key version forever, unless we set `min_decryption_version`
  to drop it.
- Post-rotation **new** encryptions use the new version (`vault:v2:…`).
- `transit/rewrap` re-encrypts a piece of ciphertext under the latest
  version WITHOUT exposing the plaintext to the caller — same-key
  envelope-rotate, server-side.

A vanilla rotate WITHOUT rewrap is cheap (one API call per key) but
leaves existing ciphertext on the old version. The blast-radius of a
"v1 key material leaked" scenario therefore stays open until you rewrap.
Rewrap pass IS the security-relevant step.

## Procedure — rotate a single org

```bash
# On a workstation with `bao login` against the live cluster:
ORG_ID=00000000-0000-0000-0000-000000000000   # fill in
KEY_NAME=pii-org-$(echo "$ORG_ID" | tr -d '-')

# 1. Confirm the org actually has a per-tenant key (post-052 / rewrap).
#    Pre-052 orgs still wrap onto `pii-encryption`; rotate the
#    platform-wide key separately (see § Rotating `pii-encryption`).
sudo -n kubectl -n control exec -i control-db-1 -c postgres -- \
  psql -U postgres -d control -c "SELECT id, transit_key_name FROM organizations WHERE id = '$ORG_ID';"

# 2. Inspect the current key version (creation_time + latest_version).
bao read transit/keys/$KEY_NAME

# 3. Rotate. Idempotent in the sense that re-running just bumps again.
bao write -f transit/keys/$KEY_NAME/rotate

# 4. Rewrap existing ciphertext onto the new version. The script reads
#    organization_stripe_config + organization_accounting_config +
#    organization_email_config + organization_app_email_config rows
#    for THIS org, calls `transit/rewrap/<key>` per *_enc column, and
#    writes back the new ciphertext atomically per table.
ssh secforge "cd ~/secforge && sudo -n kubectl -n control exec -i deploy/control -- \
  /nodejs/bin/node --import tsx /app/src/scripts/rotate-org-transit-key.ts $ORG_ID --rewrap"

# 5. Sanity: re-read the key + confirm the post-rewrap rows decrypt
#    cleanly (the admin UI Status panel will refuse to render if a
#    decrypt fails — useful smoke test).
bao read transit/keys/$KEY_NAME
```

## Procedure — rotate every org (bulk)

```bash
# Background batch — the script logs per-org status to stdout. Each
# org is its own transaction; a per-org failure does not block the
# others. Re-run is idempotent (already-on-latest keys are skipped).
ssh secforge "cd ~/secforge && sudo -n kubectl -n control exec -i deploy/control -- \
  /nodejs/bin/node --import tsx /app/src/scripts/rotate-org-transit-key.ts --all --rewrap"
```

## Rotating `pii-encryption` (the platform-wide key)

Pre-052 orgs and the `platform_billing_config` singleton both wrap
onto the global `pii-encryption` key. Rotation procedure is identical
in shape:

```bash
bao read transit/keys/pii-encryption       # version 1 today
bao write -f transit/keys/pii-encryption/rotate
# Rewrap is via the migration-052 backfill script — it already
# re-encrypts pre-052 ciphertext onto per-tenant keys, so a rotation
# of pii-encryption ONLY affects platform_billing_config + any orgs
# still on the default. Run the rewrap script first to clear the
# pre-052 backlog, THEN rotate pii-encryption for the platform row.
ssh secforge "cd ~/secforge && sudo -n kubectl -n control exec -i deploy/control -- \
  /nodejs/bin/node --import tsx /app/src/scripts/rewrap-org-vendor-keys.ts"
```

Or, if you want to retire `pii-encryption` entirely after the rewrap
sweep has migrated every org to a per-tenant key, set
`min_decryption_version` to the platform_billing_config's current
version and call it a day. The key still exists; ciphertext on older
versions becomes un-decryptable. Be sure NO row anywhere still wraps
onto it before tightening this knob.

## Rollback

Rotation itself is not destructive — the old key version stays
decrypt-capable until you explicitly set `min_decryption_version`.
**Don't** set that knob until at least one full Velero/CNPG backup
cycle has captured the rewrapped state. If a rewrap pass missed a
row (an app-email overlay you didn't know about, a hand-INSERTed
ciphertext, etc.), Member Hub's read path will throw a decrypt-error
against the rewrap target until you UPDATE that row through the
admin UI to mint fresh ciphertext on the latest version.

## Cipher orphan recovery (post-OpenBao-restore)

Different failure mode from rotation. When the per-org Transit key
has been **destroyed and recreated** — most likely after an OpenBao
admin recovery flow (the 2026-05-19 incident is the canonical
example) — the previously-stored ciphertext is unrecoverable.
`transit/rewrap` cannot help here: the new key is unrelated to the
old one, so OpenBao can't decrypt the old ciphertext to re-encrypt
it. There IS no plaintext-on-disk to read; the rotation script
will fail with "cipher: message authentication failed" on the
first decrypt attempt.

**Recovery path is operator-driven via the admin Integrations UI.**
Migration 054 + 055 added a `needs_reconnect` column to every
vendor-credential table; the system endpoints (`system-accounting-
config`, `system-stripe-config`, `system-email-config`) flip this
flag to TRUE when their decrypt call throws. The admin Integrations
page (admin.${DOMAIN}/admin/integrations) renders an affected row
with a yellow **Reconnection Required** pill + an inline banner
explaining what happened.

Per-integration recovery:

| Integration | Operator action | Result |
|---|---|---|
| **QuickBooks Online** | Click **Reconnect QuickBooks** — same OAuth flow as initial connect. | Fresh tokens encrypted under the current key; `needs_reconnect` cleared. |
| **Stripe** | Paste a fresh Stripe Secret Key + **Save Changes**. Webhook signing secret too if Stripe also rotated. | Fresh ciphertext under current key; flag cleared on save. |
| **Email (Postmark or SMTP)** | Type the Postmark server token OR the SMTP password into the affected ConfigForm + **Save**. | Fresh ciphertext under current key; flag cleared on save. The org default and each app override carry independent flags. |

The opportunistic verify on every `/raw` and status read also flips
the flag forward when the system endpoint hasn't been hit yet — so
the operator sees the badge on first page-load, no waiting for a
send to fail. Until the operator clicks Reconnect / re-saves the
secret, the underlying system endpoint returns null credentials and
sends are skipped with a truthful audit reason (`system_email_config_
fetch_failed`, `provider:none`, etc.) — Member Hub's rule engine
honestly reports the skip rather than claiming the send succeeded
(see Member Hub commit `fd00ff8`).

If the cipher orphan affects orgs that no operator is reachable for
(e.g., bulk recovery of a dead realm), the only option is to clear
the affected ciphertext columns by hand:

```sql
-- Per-org, after confirming the operator cannot recover via UI.
-- NOTE: this loses the stored credential — they MUST be re-entered
-- by the operator or via a separate provisioning channel.
UPDATE organization_stripe_config
   SET stripe_secret_key_enc = NULL,
       stripe_webhook_secret_enc = NULL,
       needs_reconnect = FALSE,
       updated_at = now()
 WHERE org_id = '<orgId>';
```

Same shape for `organization_accounting_config` (qbo_*_enc),
`organization_email_config` (postmark_server_token_enc, smtp_
password_enc), and `organization_app_email_config`.

## Aging check (proactive rotation signal)

The age-report script lists every per-org Transit key with the
number of days since its LATEST version was created. Operators wire
it into either a daily CronJob (alert on exit code 1) or a one-off
run when reviewing key hygiene:

```bash
ssh secforge "cd ~/secforge && sudo -n kubectl -n control exec -i deploy/control -- \
  /nodejs/bin/node --import tsx /app/src/scripts/transit-key-age-report.ts --threshold-days 365"
```

`--json` swaps the human report for a machine-readable payload
suitable for piping into other tooling. Exits 1 when at least one
key crosses the threshold OR when an OpenBao read fails (so a
wrapping alert can fire on either condition).

Default threshold is 365 days — the lower bound of the 12-24 month
application-key rotation cadence in § When to rotate.

## Audit trail

Every Transit operation (`encrypt`, `decrypt`, `rewrap`, `rotate`,
the `keys/<name>` reads) lands in OpenBao's audit device. Grep
post-incident with:

```bash
sudo -n kubectl -n openbao logs openbao-0 | grep -E "rotate|rewrap" | jq .
```

Control also audits each per-org rewrap into `audit.event` via
`org.crypto.rotated` (recorded by the rotation script).

## Not covered

- **CronJob automation.** Today rotation is operator-driven. A
  `transit-key-age-report-daily` CronJob in the `control` namespace
  is the next obvious step — it would run the age-report script
  above on a schedule and Alertmanager-fire on a non-zero exit.
  Auto-rotation (run `rotate-org-transit-key.ts --all --rewrap` on
  a cadence) stays operator-confirmed for now; the audit-trail
  clarity of explicit invocation is worth more than the convenience
  while tenant count is small.
- **Cross-org rewrap (i.e., rotating the wrap KEY of an org's
  data).** The cross-key rewrap path is in `rewrap-org-vendor-keys.ts`
  (the migration-052 back-fill). That's different from same-key
  version rotation — this runbook only covers the latter.
