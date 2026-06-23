# Runbook — member-hub DB restore (encrypted-PII aware)

> Audit ref: **M-8 follow-on / Phase-4 Deploy-3**. Restores the Member Hub
> Postgres (`member-hub-db`, namespace `member-hub`) from a CNPG/barman backup.
> Pairs with [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md) (OpenBao
> DR) and [control-db-restore.md](./control-db-restore.md) (the Control-plane
> analogue + the ordered-DR pattern).
>
> Last tested: **NOT YET** — author a CNPG restore drill into a scratch Cluster
> and confirm a decrypt round-trip (§5) before relying on this.

## ⚠️ 0. The one thing that makes this runbook different

Since **migration 122 (Phase 4 Deploy 3, 2026-06-22)** the `members.email`
column is **gone**. A member's email exists ONLY as:

- `members.email_enc`  — OpenBao Transit ciphertext (`pii-encryption` key)
- `members.email_hmac` — HMAC-SHA256 lookup (key `EMAIL_HMAC_KEY`)

Both keys live in the **main OpenBao** (`data-openbao-*` Raft store). There is
**no plaintext fallback anymore** — the column that used to make emails
recoverable without OpenBao no longer exists.

**Consequence:** restoring the member-hub Postgres backup ALONE recovers
nothing usable for member email. You also need the matching OpenBao
`pii-encryption` Transit key (any key version ≥ the one that encrypted the
rows — Transit keeps old versions, so a key *rotation* is fine; a key
*deletion* or a total OpenBao loss is **permanent, unrecoverable member-PII
loss**). The HMAC key only affects lookup, not recoverability, but a different
`EMAIL_HMAC_KEY` breaks login-by-email / dedupe until re-derived.

**Therefore OpenBao must be restored (or intact) BEFORE the member-hub DB is
trusted as restored** — exactly the ordered-DR rule in control-db-restore.md,
but here the failure mode is data loss, not just a boot failure.

## 1. Backup inventory (what protects the keys today)

- **member-hub Postgres**: CNPG scheduled backup `member-hub-db-daily` →
  MinIO/barman object store (verify: `kubectl get backup -n member-hub`).
- **OpenBao Raft (holds the `pii-encryption` Transit key + `EMAIL_HMAC_KEY`)**:
  - **Velero** `daily-everything` fs-backups the `data-openbao-*` PVCs daily.
    This is the *current* OpenBao backup. CAVEAT: it is a filesystem copy of a
    LIVE Raft DB and is therefore the method ADR-0020 deemed potentially
    inconsistent on restore.
  - The **application-consistent** `bao operator raft snapshot save` CronJob
    (ADR-0020) is now **DEPLOYED** (operator-backlog #96,
    `platform/manifests/openbao/14-openbao-raft-snapshot.yaml`): every 6h it
    writes a consistent `.snap` to the `openbao-raft-snapshots` PVC, which
    Velero ships off-cluster — the preferred recovery artifact. Restore from
    one via `bao operator raft snapshot restore` (per ADR-0020 §Recovery; a
    detailed `openbao-backup-restore.md` is still pending). The Velero PVC copy
    remains a secondary path.
- **Seal keys**: offline Shamir 3-of-5 ([ADR-0009](../02-decisions/0009-openbao-seal-strategy.md)).
  A snapshot/PVC copy is useless without the Shamir threshold.

## 2. Targeted recovery (member-hub DB only, OpenBao intact)

The common case — bad migration, corruption, accidental delete — with OpenBao
healthy. Standard CNPG restore; the keys are already live, so decrypt works
once the app reconnects.

1. Restore the CNPG Cluster from the chosen backup into a replacement Cluster
   (see CNPG `Cluster.spec.bootstrap.recovery` / barman). Do NOT point the live
   app at it until §5 passes.
2. Run pending migrations if the backup predates HEAD (`pnpm db:migrate` Job).
3. Proceed to §5 (verify decrypt round-trip), then cut the app over.

## 3. Full-cluster-loss DR (ordered, OpenBao first)

1. **OpenBao first** — restore per [ADR-0020](../02-decisions/0020-openbao-backup-and-dr.md)
   + [openbao-recovery.md](./openbao-recovery.md): stand up OpenBao, restore the
   Raft data (Velero PVC restore today; the consistent snapshot once the
   CronJob exists), unseal with the Shamir threshold. **Confirm the
   `pii-encryption` Transit key is present** before trusting any MH restore:
   `vault read transit/keys/pii-encryption` (expect `latest_version` ≥ 1).
2. **Then member-hub DB** — restore the CNPG Cluster (§2 steps).
3. **Then the app** — it fails closed at boot without OpenBao (no
   `OPENBAO_ADDR`/keys ⇒ the dev codec is refused under NODE_ENV=production),
   so it only serves once both layers are back.

## 4. The unrecoverable case (know it cold)

If the OpenBao Raft data is lost AND no usable backup (Velero copy corrupt /
Shamir keys lost) exists, the `pii-encryption` key is gone and **every member
email is permanently undecryptable**. There is no recovery — the plaintext was
dropped in migration 122. This is the reason the OpenBao backup is now
load-bearing for member PII; treat its health as a P1 concern (see §1 caveat
about deploying the consistent-snapshot CronJob).

## 5. Verify gate (run before every cutover)

Against the restored DB, with OpenBao reachable:

```
# 1. Schema is post-122 (no plaintext column; enc/hmac NOT NULL):
SELECT column_name, is_nullable FROM information_schema.columns
 WHERE table_name='members' AND column_name LIKE '%email%';   -- expect email_enc:NO, email_hmac:NO, no `email`

# 2. Every row has ciphertext:
SELECT count(*) total, count(*) FILTER (WHERE email_enc IS NULL) enc_null,
       count(*) FILTER (WHERE email_hmac IS NULL) hmac_null FROM members;  -- enc_null=0, hmac_null=0

# 3. Decrypt round-trip (in-pod, app boundary): a known member's email
#    resolves to plaintext via the app's member-pii layer (e.g. an authed
#    GET that lists a member) — confirms the restored ciphertext matches the
#    restored Transit key version. If decrypt fails, the OpenBao key and the
#    DB backup are from incompatible points — re-check §3 step 1.
```

A restore is only "good" when step 3 returns real plaintext — that is the
single check that proves DB-backup and Transit-key are mutually consistent.
