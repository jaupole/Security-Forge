# Transit Field-Level Encryption for PII

> Architecture: [docs/01-architecture/05-secrets-management.md](../01-architecture/05-secrets-management.md)
> Source-of-truth files:
> - Go client: [`apps/lib/secrets/transit.go`](../../apps/lib/secrets/transit.go)
> - Sample policy: [`infrastructure/openbao/policies/helloworld-bff.hcl`](../../infrastructure/openbao/policies/helloworld-bff.hcl)
> - Transit key: `transit/keys/pii-encryption` (aes256-gcm96, provisioned at platform install time)

## TL;DR

For PII columns in app Postgres (emails, names, addresses, free-text notes, anything you wouldn't want a database admin or a backup operator to read in cleartext), encrypt the value before write and decrypt on read using OpenBao's **Transit** secrets engine. The app never holds the key — every encrypt/decrypt is an authenticated API call against `transit/encrypt/pii-encryption` (or a per-app key).

This is **field-level** encryption, complementary to:
- **Storage-level encryption** (MinIO SSE-S3, Phase C #2) — protects backup blobs at rest in MinIO. Helps against storage exfiltration.
- **Backup encryption** (Velero kopia + MinIO SSE-S3) — protects exported PV/CNPG dumps. Helps against backup compromise.

Transit field encryption protects against a fourth threat **the others don't cover**: a database operator (or compromised admin tool with read-only Postgres access) seeing PII directly in `SELECT *`. The data is ciphertext at rest in the Postgres rows, in WAL, in `pg_dump`, and in the CNPG barman backups.

## When to use it (and when not)

**Use Transit field encryption for:**
- Personal identifiers — full name, email, phone, address, government IDs
- Free-text user content — notes, messages, journal entries
- Authentication artifacts that aren't already hashed — API tokens issued by the app, OAuth refresh tokens stored for offline access
- Anything a regulator (GDPR, CCPA, HIPAA) would call "personal data"

**Don't use it for:**
- Passwords — those are bcrypt/argon2-hashed, never reversible. Hashing is stronger here.
- Foreign keys, IDs, timestamps, anything you JOIN, ORDER, or WHERE on. Encrypted columns are opaque blobs; you can't index them. (Exception: deterministic Transit with `derived=true` + a context — niche pattern, document specifically if you need it.)
- High-volume telemetry (events, logs, metrics) — the per-row API call cost adds up. Do storage-level encryption only.
- Anything already public (display names users opted to publish, public profile fields).

## Storage shape

Encrypted values are stored as `text` in Postgres with the literal OpenBao ciphertext format:

```
vault:v1:hRiSzN+kLs3qY8fDJ...
```

The `:v1:` is the key version — automatically updated by OpenBao when the key is rotated. Don't strip it; don't normalize it; don't store a pre-decoded variant. Decryption fails without the prefix, and key rotation needs the version number to find the right historical key material.

Schema sketch (Prisma):

```prisma
model User {
  id        String   @id @default(cuid())
  emailEnc  String   // ciphertext of email; vault:v1:...
  nameEnc   String   // ciphertext of full_name; vault:v1:...
  createdAt DateTime @default(now())

  // ENCRYPTED — never query by these columns directly. If you need
  // lookup-by-email, add a `email_lookup_hash` column with a salted
  // HMAC of the lowercase email and query by that. Salting + HMAC is
  // application-layer, NOT Transit — different threat model.
}
```

If you need lookup-by-encrypted-field, the **blind index** pattern (HMAC-SHA256 with a per-key salt also kept in OpenBao) is the standard add-on. Don't conflate the two — Transit handles confidentiality, the blind index handles searchability.

## Go usage (SecForge in-cluster apps)

Apps that already use [`apps/lib/secrets/`](../../apps/lib/secrets/) for KV reads can pull in the Transit client the same way.

### 1. Provision the policy

Per-app OpenBao policy granting encrypt/decrypt on the shared `pii-encryption` key. Minimal example (drop into `infrastructure/openbao/policies/<your-app>.hcl`):

```hcl
# Per-app policy, bound to the app's SPIFFE-ID via the JWT auth role.

# ... (existing KV reads, dynamic DB creds, etc.) ...

# Transit: encrypt + decrypt PII fields.
path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}
```

This mirrors `infrastructure/openbao/policies/helloworld-bff.hcl`, the canonical example.

If you want a per-app key (different blast radius — compromised app A can't decrypt app B's data), add a `transit/keys/<app>-pii` key in your app's bootstrap script and reference it instead of `pii-encryption` in both the policy and the client constructor.

### 2. Construct the client

```go
import "github.com/secforge/lib/secrets"

tc, err := secrets.NewTransitClient(
    os.Getenv("OPENBAO_ADDR"),     // https://openbao.openbao.svc:8200
    "/shared/openbao.jwt",         // SPIRE-written JWT-SVID
    "your-app",                     // OpenBao auth/jwt role for this app
    "pii-encryption",              // Transit key (or a per-app variant)
)
if err != nil {
    return fmt.Errorf("transit client: %w", err)
}
```

The same JWT-SVID file used by `OpenBaoBootstrapper` is reused — the spiffe-helper init container writes it once at pod startup.

### 3. Encrypt on write, decrypt on read

```go
// Encrypt before INSERT.
ct, err := tc.Encrypt(ctx, []byte(user.Email))
if err != nil { return err }

_, err = db.ExecContext(ctx,
    `INSERT INTO users (id, email_enc) VALUES ($1, $2)`, user.ID, ct)

// Decrypt on read. Secret is redaction-aware — fmt.Println prints
// "[redacted]"; the bytes are zeroed after Use returns.
var ct string
db.QueryRowContext(ctx, `SELECT email_enc FROM users WHERE id=$1`, id).Scan(&ct)

s, err := tc.Decrypt(ctx, ct)
if err != nil { return err }

err = s.Use(func(b []byte) error {
    user.Email = string(b)   // copy out — DON'T retain b past Use's return
    return nil
})
```

For batch decrypts (rendering a list of N users), just call `Decrypt` in a loop — the OpenBao token is cached in-memory and reused. If you find yourself decrypting >50 rows per request, switch to OpenBao's batch endpoint (not yet exposed by this client; open an issue when you need it).

## TypeScript / Prisma usage (Proposal Forge, Project Tracker)

The Node apps don't yet ship a transit client; the recommended pattern is a Prisma Client extension that auto-encrypts/decrypts annotated fields.

### 1. Direct API client

```ts
// shared/secrets/transit.ts
import { readFile } from "node:fs/promises";

export class TransitClient {
  private token?: string;
  private expiresAt = 0;

  constructor(
    private readonly addr: string,        // e.g. https://openbao.openbao.svc:8200
    private readonly jwtPath: string,     // /shared/openbao.jwt
    private readonly role: string,        // "proposal-forge"
    private readonly keyName: string,     // "pii-encryption"
  ) {}

  async encrypt(plaintext: string): Promise<string> {
    const tok = await this.tokenFor();
    const res = await fetch(`${this.addr}/v1/transit/encrypt/${this.keyName}`, {
      method: "POST",
      headers: { "X-Vault-Token": tok, "Content-Type": "application/json" },
      body: JSON.stringify({
        plaintext: Buffer.from(plaintext, "utf8").toString("base64"),
      }),
    });
    if (res.status === 403) { this.invalidateToken(); throw new Error("transit 403"); }
    if (!res.ok) throw new Error(`transit encrypt ${res.status}`);
    const { data } = await res.json();
    return data.ciphertext;  // vault:v1:...
  }

  async decrypt(ciphertext: string): Promise<string> {
    if (!ciphertext.startsWith("vault:v")) {
      throw new Error("transit: ciphertext missing vault:v<n>: prefix");
    }
    const tok = await this.tokenFor();
    const res = await fetch(`${this.addr}/v1/transit/decrypt/${this.keyName}`, {
      method: "POST",
      headers: { "X-Vault-Token": tok, "Content-Type": "application/json" },
      body: JSON.stringify({ ciphertext }),
    });
    if (res.status === 403) { this.invalidateToken(); throw new Error("transit 403"); }
    if (!res.ok) throw new Error(`transit decrypt ${res.status}`);
    const { data } = await res.json();
    return Buffer.from(data.plaintext, "base64").toString("utf8");
  }

  private async tokenFor(): Promise<string> {
    if (this.token && Date.now() < this.expiresAt) return this.token;
    const jwt = (await readFile(this.jwtPath, "utf8")).trim();
    const res = await fetch(`${this.addr}/v1/auth/jwt/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ role: this.role, jwt }),
    });
    if (!res.ok) throw new Error(`transit login ${res.status}`);
    const { auth } = await res.json();
    this.token = auth.client_token;
    this.expiresAt = Date.now() + (auth.lease_duration - 30) * 1000;
    return this.token!;
  }

  private invalidateToken() { this.token = undefined; this.expiresAt = 0; }
}
```

### 2. Prisma Client extension

Prisma 6.x replaces `$use` middleware with `$extends` client extensions. The pattern:

```ts
// shared/prisma/encryption-extension.ts
import { Prisma } from "@prisma/client";
import type { TransitClient } from "../secrets/transit";

// Mark which fields are encrypted, per model. Centralized list — easier to
// audit than a `@encrypted` Prisma annotation, and Prisma extensions don't
// have a way to read schema-level decorators.
const ENCRYPTED_FIELDS: Record<string, string[]> = {
  User: ["email", "fullName", "phone"],
  Note: ["content"],
};

export function withEncryption(transit: TransitClient) {
  return Prisma.defineExtension({
    name: "secforge-transit-encryption",
    query: {
      $allModels: {
        async create({ model, args, query }) {
          await encryptIn(transit, model, args.data);
          const result = await query(args);
          await decryptOut(transit, model, result);
          return result;
        },
        async update({ model, args, query }) {
          await encryptIn(transit, model, args.data);
          const result = await query(args);
          await decryptOut(transit, model, result);
          return result;
        },
        async findUnique({ model, args, query }) {
          const result = await query(args);
          await decryptOut(transit, model, result);
          return result;
        },
        async findMany({ model, args, query }) {
          const results = await query(args);
          for (const r of results ?? []) await decryptOut(transit, model, r);
          return results;
        },
      },
    },
  });
}

async function encryptIn(t: TransitClient, model: string, data: any) {
  const fields = ENCRYPTED_FIELDS[model];
  if (!fields || !data) return;
  for (const f of fields) {
    if (typeof data[f] === "string" && !data[f].startsWith("vault:v")) {
      data[f] = await t.encrypt(data[f]);
    }
  }
}

async function decryptOut(t: TransitClient, model: string, row: any) {
  const fields = ENCRYPTED_FIELDS[model];
  if (!fields || !row) return;
  for (const f of fields) {
    if (typeof row[f] === "string" && row[f].startsWith("vault:v")) {
      row[f] = await t.decrypt(row[f]);
    }
  }
}
```

### 3. Wire it up

```ts
// shared/prisma/client.ts
import { PrismaClient } from "@prisma/client";
import { TransitClient } from "../secrets/transit";
import { withEncryption } from "./encryption-extension";

const transit = new TransitClient(
  process.env.OPENBAO_ADDR!,
  "/shared/openbao.jwt",
  process.env.OPENBAO_ROLE!,    // "proposal-forge" or "project-tracker"
  "pii-encryption",
);

export const prisma = new PrismaClient().$extends(withEncryption(transit));
```

### Schema notes

Encrypted fields stay typed `String` (not `Bytes`) because OpenBao ciphertext is ASCII (`vault:v1:<base64>`). Prefix the column name with `Enc` or annotate with a comment so future-you remembers it's not directly queryable:

```prisma
model User {
  id        String   @id @default(cuid())
  email     String   /// ENCRYPTED via Transit (pii-encryption key)
  fullName  String?  /// ENCRYPTED via Transit (pii-encryption key)
}
```

The Prisma extension's `ENCRYPTED_FIELDS` map is the source of truth for which fields the auto-encrypt/decrypt applies to — the comment on the Prisma model is for human readers.

## Per-app OpenBao role bootstrap

The platform script that creates an app's OpenBao bootstrap (SA, JWT auth role, policy) needs to include the Transit policy block. For Proposal Forge / Project Tracker, the canonical script is the per-app `bootstrap-app.sh` flow ([platform/components/bootstrap-app.sh](../../platform/components/bootstrap-app.sh)).

Pass `APP_OPENBAO_PATHS` including the transit paths:

```bash
APP_OPENBAO_PATHS='["secret/data/apps/proposal-forge/+","transit/encrypt/pii-encryption","transit/decrypt/pii-encryption"]'
```

The bootstrap renders these into the per-app HCL policy and registers the policy with the JWT auth role. The app's Pod gets a JWT-SVID via spiffe-helper, exchanges via auth/jwt/login, and hits Transit with the resulting token. No static credentials anywhere.

## Key rotation

Rotation is a single OpenBao API call:

```bash
bao write -f transit/keys/pii-encryption/rotate
```

This creates `pii-encryption` version 2. **Existing ciphertexts continue to decrypt** — they reference `vault:v1:` and OpenBao keeps historical versions until you set `min_decryption_version` to deprecate them. New encryptions use v2 automatically.

To force-rewrap existing data so old ciphertext versions can be retired:

```bash
# Per row; the app can do this lazily on next write OR proactively in
# a rewrap job. The /rewrap endpoint generates new ciphertext under
# the latest key version without exposing plaintext to the caller.
bao write transit/rewrap/pii-encryption ciphertext='vault:v1:...'
# returns vault:v2:...; UPDATE the row.
```

Once all rows are at v2, retire v1:

```bash
bao write transit/keys/pii-encryption/config min_decryption_version=2
```

This is the safe rotation pattern. **Do NOT** delete the key version (`min_available_version`) until you're certain no backups still hold v1 ciphertext — restoring a 30-day-old CNPG backup of a v1-only row would otherwise fail decryption.

## Operational considerations

**Latency.** Each encrypt/decrypt is an HTTP round-trip to OpenBao. Realistic budget: 2-5 ms p50 in-cluster. For a request that touches 1-3 PII fields, the overhead is negligible. For a list view of 100 users, it's 200-500 ms — switch to batch (`/encrypt/<key>/batch`) or denormalize.

**Failure modes.** When OpenBao is down or the auth/jwt role is misconfigured, all encrypted reads fail. Cache strategically: it's reasonable for a BFF to cache decrypted user emails for the request lifetime, so a single OpenBao blip doesn't blow up the page. Don't cache across requests unless you have a clear policy on cache eviction (e.g., session-scoped).

**Audit trail.** OpenBao audit logs every `transit/encrypt` and `transit/decrypt` call with the caller's identity (the SPIFFE-ID via JWT auth alias). This is a privileged-action log: who decrypted whose PII, when. Wire it to Loki via the openbao-audit Promtail pipeline (see [migration-to-vps.md](../99-archive/migration-to-vps.md) Phase E).

**Backup compatibility.** CNPG backups are now SSE-S3 encrypted at rest in MinIO (Phase C #2 storage-layer hardening). The Postgres-row contents (`vault:v1:...` strings) are also application-layer encrypted via Transit. **Both layers must be available to restore working data**:

1. The MinIO SSE-S3 master key (in OpenBao at `secret/data/platform/minio/sse-master-key`) — needed to read the backup blob from MinIO.
2. The Transit `pii-encryption` key — needed to decrypt the row contents after restore.

Lose either, lose the data. The OpenBao Raft cluster + the OpenBao operator-recovery procedure (unseal keys + root token escrow) is the actual single point of failure here. Document that recovery story before rolling out Transit field encryption to your first real PII column.

## Threat model checklist

| Threat | Defense |
|---|---|
| DBA reads `users` table directly | ✅ Row contents are ciphertext |
| `pg_dump` exfiltrated by attacker | ✅ Dump contains ciphertext only |
| MinIO backup blob exfiltrated | ✅ MinIO SSE-S3 (Phase C #2) + ciphertext-on-row |
| OpenBao root token compromised | ❌ Attacker can decrypt all PII via Transit. Mitigation: never leave `openbao-root-token-tmp` Secret in-cluster (active enforcement during deploy work — see project memory). |
| App pod compromised | ⚠️ Attacker has the SPIFFE-ID and can decrypt anything the app's policy permits. Mitigation: scope policy to only the keys the app actually needs; per-app keys (`<app>-pii`) instead of shared `pii-encryption` for stronger blast-radius isolation. |
| OpenBao Raft cluster lost | ❌ All encrypted data is unrecoverable. Mitigation: operator-recovery procedure (unseal keys offline, root token escrow). |
| Side-channel on Transit calls | ⚠️ TLS in-cluster + audit log; monitor anomalous decrypt rates (alert on `>10× baseline` per app). |

## Status

- ✅ Transit engine mounted and `pii-encryption` key provisioned at platform install.
- ✅ Sample policy: `helloworld-bff.hcl` grants encrypt/decrypt on the shared key.
- ✅ Go client: [`apps/lib/secrets/transit.go`](../../apps/lib/secrets/transit.go) + tests.
- ⏳ TypeScript client + Prisma extension: documented above; not yet shipped to Proposal Forge / Project Tracker. Drop into `shared/` when those repos start storing PII.
- ⏳ Audit dashboard for Transit operations: TODO (Phase 7-rest).
- ⏳ Per-app key option (`<app>-pii` instead of shared `pii-encryption`): supported by client, not yet by `bootstrap-app.sh` template variables. Add when the first app needs it.
