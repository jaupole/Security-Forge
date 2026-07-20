# Design: OpenBao Transit key rotation

> Status: DESIGN (2026-07-20) — no rotation has ever been performed. Written
> while the encrypted footprint is small (operator-backlog: design-while-small).
> Executing this requires a root-token deploy day for the policy additions;
> everything else runs under existing app credentials.

## Inventory (what encrypts under Transit today)

| Key | Type | Consumers | Ciphertext locations |
|---|---|---|---|
| `transit/keys/pii-encryption` | aes256-gcm96 | Control (legacy/global default, `TRANSIT_KEYNAME`), Member Hub (`member-pii.ts`) | Control pre-052 org rows awaiting the org-key rewrap pass; Member Hub `email_enc`, `p_email_enc` |
| `transit/keys/pii-org-<32hex>` (per org) | aes256-gcm96 | Control `org-crypto.ts` (minted at signup, `keyNameFor()`), vendor-credentials, accounting-config | Control org-scoped `*_enc` rows; each org row records its key in `organizations.transit_key_name` |
| `transit/keys/audit-signing` | ed25519, `deletion_allowed=false` | Audit anchor/verifier CronJobs (sign + verify) | Signatures in the anchor chain (GitHub `secforge-audit-anchors`) |

Transit ciphertexts embed their key version (`vault:vN:...`), so old versions
stay decryptable after rotation until `min_decryption_version` is raised.

## Design

### 1. Rotate (cheap, safe, instant)
`bao write -f transit/keys/<key>/rotate` — new version becomes encrypt-default;
decrypt still accepts all versions ≥ `min_decryption_version`. Nothing breaks.
Cadence: **quarterly + on-incident** (key-compromise suspicion, operator
departure — n/a solo, codified anyway).

### 2. Rewrap sweep (moves ciphertext to the new version, no plaintext exposure)
`transit/rewrap/<key>` re-encrypts server-side. Per consumer:
- **Control**: generalize the existing pre-052 org-key rewrap pass into a
  reusable sweep — `SELECT ... WHERE col !~ '^vault:v<latest>:'` per `*_enc`
  column, POST rewrap, UPDATE row. Idempotent, batched, resumable.
- **Member Hub**: same shape over `email_enc`, `p_email_enc` (small script in
  `src/lib/member-pii.ts`'s module, run as a one-off Job).
- Verification query per table: zero rows matching `vault:v(0|..|N-1):` before
  step 3.

### 3. Retire old versions
`bao write transit/keys/<key>/config min_decryption_version=N` — ONLY after
step-2 verification is zero everywhere. This is the actual security payoff:
old-version ciphertext (e.g. exfiltrated backups) becomes undecryptable even
with a future token compromise.

### 4. audit-signing is different — never retire versions
Signature verification embeds the version; historic anchor-chain verification
must keep working forever. Rotate freely (new signatures use the new version),
but **never** raise `min_decryption_version`/`min_encryption_version` and never
delete the key (`deletion_allowed=false` already enforces the latter).

## Prerequisites (the root-token day items)

1. App policies today grant encrypt/decrypt only — add `update` on
   `transit/rewrap/pii-encryption` (Member Hub role) and
   `transit/rewrap/pii-org-*` + `transit/rewrap/pii-encryption` (Control role)
   in the 05-series policy scripts.
2. New `05m-transit-rotate.sh` component: rotates the named keys + prints the
   per-consumer sweep/verify commands (rotate + config writes are admin ops).

## Explicitly out of scope
- KV-v2 static secret rotation (client secrets, tokens) — separate concern,
  covered by the existing per-secret rotation runbooks.
- Datastore-level re-keying (CNPG TDE is not in use; disk is LUKS-encrypted).

## Effort
Prereqs ~1h (policy + script, root-token day). Control sweep generalization
~2-3h (the org-key rewrap pass exists as a template). MH sweep ~1h. First
full rotation cycle: one afternoon, then quarterly ~30min.
