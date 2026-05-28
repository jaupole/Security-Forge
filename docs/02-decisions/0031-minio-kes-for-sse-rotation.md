# ADR-0031: MinIO KES for SSE-S3 key rotation — SUPERSEDED by drain-and-rotate (2026-05-28 evening amendment)

**Status**: Superseded for the 2026-05-28 rotation cycle — KES design retained as the fallback architecture if/when MinIO commercial offerings clarify the substrate decision (operator-backlog #56). Drain-and-rotate executed instead; see § "2026-05-28 evening amendment" below.
**Date**: 2026-05-28
**Decision-makers**: Project owner
**Phase**: Hetzner bare-metal hardening (post-Phase C #2)

## 2026-05-28 evening amendment

Between the morning design pass (this ADR's original body) and the evening execution window, research surfaced that **`minio/kes` is archived upstream as of 2025-06-19**, with the last release being `2025-03-12T09-35-18Z`. Future security patches will not come from the upstream repo. This aligns with the broader MinIO commercialization signal logged in operator-backlog **#56** (MinIO has effectively stopped publishing public open-source MinIO server release images after `RELEASE.2025-09-07T16-13-09Z`).

This changes the cost-benefit on deploying KES:
- **Before this finding**: KES is the documented, supported MinIO pattern for SSE-S3 key rotation. Half-day cost to add it as a long-term platform component, gains forever-rotation.
- **After this finding**: KES is a frozen-upstream codebase. Deploying it adds a permanent maintenance dependency on dead software. Real "long-term" rotation requires whatever substrate decision lands from #56 (Garage / SeaweedFS / Hetzner Object Storage / commercial MinIO).

**Decision flipped:** for the 2026-05-28 rotation cycle, execute **drain-and-rotate** instead of deploying KES. Drain-and-rotate is a one-shot fix that closes the immediate historical-plaintext exposure (the previous master key value sitting in state.db kine MVCC) without committing to a frozen-upstream platform component. The KES design captured below is retained as the architecture-of-record IF the #56 substrate decision lands on continuing with MinIO (commercial or otherwise) — at which point we revisit and consider KES again with up-to-date maintenance signals.

**Drain-and-rotate execution (2026-05-28 evening):**

1. Inventory all SSE-encrypted MinIO data: `backups/` (1.2 GiB, regeneratable — CNPG barman + Velero resource backups), `member-hub-documents/` (3.6 KiB, 2 objects — real user data), 5 other empty buckets.
2. Drain `member-hub-documents/` objects to local box disk via `mc cp` while the OLD master key is still active (MinIO decrypts on GET). sha256 the staged copies.
3. Wipe SSE-encrypted prefixes: `mc rm --recursive --force` for `backups/cnpg/`, `backups/velero/`, `member-hub-documents/`, `backups/sse-verify/`. Other buckets are empty.
4. Generate new 32-byte master key with new name (`secforge-minio-key-2026-05-28-<short-suffix>`).
5. Write to OpenBao at `secret/data/platform/minio/sse-master-key` (`key_name=…`, `master_key_b64=…`) via break-glass admin token (#34 / #69-deferred).
6. Wait for VSO to render new `minio-kms-creds` Secret (refreshAfter 60s).
7. Restart MinIO Deployment; verify Ready + can encrypt a test write.
8. Re-upload `member-hub-documents/` from local-disk stage; verify sha256 round-trip matches.
9. Trigger fresh CNPG base backup per cluster (control, keycloak, member-hub, spicedb) — each generates a fresh barman base backup under the new key, restoring per-cluster RPO.
10. Trigger immediate Velero backup to re-seed `backups/velero/` under the new key.
11. Verify the OLD master key value (which was historically in state.db plaintext) is now functionally dead — no remaining encrypted objects reference it.

**Risk window during rotation:** between step 3 (wipe) and step 9 (CNPG base backups re-established), the 4 CNPG clusters have no current barman backup. WAL archiving resumes the moment MinIO is back (step 7) but base backups don't exist until step 9. If a CNPG cluster's primary pod dies in that ~10-minute window AND WAL archiving was interrupted before completing the new base, point-in-time recovery is lost back to the last pre-rotation backup, which is also wiped. Mitigation: keep the window short (single bash batch executes steps 7–9 in <10 minutes), do during low-load period (executed 23:00 UTC 2026-05-28).

**Why this is acceptable risk:** the CNPG primary pods have been running 8d+ with zero crashes; the probability of a primary failure in a 10-minute window is bounded. PV backup history via Velero kopia was already wiped earlier in the same session for the kopia passphrase rotation, so the overall data-loss-on-disaster posture is unchanged.

---

## Original KES design (retained as fallback architecture)

## Context

The 2026-05-08 encryption hardening landed MinIO SSE-S3 with a single master key
provided via the `MINIO_KMS_SECRET_KEY` environment variable (static KMS).
A 2026-05-28 audit of the encryption-at-rest posture found:

1. The static master key (`secforge-minio-key:…`) was extractable in plaintext
   from `/var/lib/rancher/k3s/server/db/state.db` via `strings` (k3s etcd
   Secrets-encrypt was off; enabled in the same session). The key wraps every
   data-encryption-key (DEK) on every object in `cnpg/`, `member-hub-documents/`,
   and `velero/` prefixes.
2. MinIO's static-KMS mode supports exactly one master key. Changing the key
   value while keeping the name renders every existing object's DEK
   unwrappable. There is no in-place rotation primitive.
3. `mc encrypt rotate` exists but requires KES (Key Encryption Service) — a
   MinIO sidecar that orchestrates per-key versioning and per-object DEK
   re-wrapping.
4. The current trust-root chain for SSE-S3 master key is
   `OpenBao → VSO → K8s Secret → MINIO_KMS_SECRET_KEY env var`. The K8s Secret
   sits in etcd; the env var sits in the pod's process environment for the
   pod's lifetime. Pre-Secrets-encrypt enablement, both were plaintext on disk.

To close the rotation gap without destroying user-uploaded documents
(`member-hub-documents/` is real tenant data), we need KES. The drain-and-rotate
alternative — stream every object out, wipe, stream back in — is one-shot,
doesn't improve the architecture, and creates a window where the bucket is
inconsistent if anything fails mid-copy.

## Decision

Deploy **MinIO KES with an OpenBao-backed keystore**, k8s-auth, and
cert-manager-issued mTLS. Migrate MinIO from static-KMS to KES.

### Five sub-decisions

#### 1. Keystore backend: OpenBao via the Vault keystore plugin

KES has a `vault` keystore plugin that talks the HashiCorp Vault KV-v2 API.
OpenBao's KV-v2 implementation is API-compatible.

| Alternative | Why rejected |
|---|---|
| `fs` keystore (KES local file) | Moves the "where does the unlocker live" problem from MinIO to KES. Same offline-disk threat surface; not an improvement. |
| Cloud KMS plugin | We don't have one. Would be a separate ADR if Hetzner ever offers KMS. |

**Chosen:** OpenBao at `secret/data/kes/keys/<key-name>`. Each KES-managed key
is a KV entry; OpenBao's existing Transit-seal chain wraps the keystore data at
rest. KES becomes a thin rotation orchestrator, not a new keystore.

#### 2. KES → OpenBao auth: Kubernetes auth

KES authenticates as a Kubernetes ServiceAccount; OpenBao verifies via
TokenReview API. Matches the existing pattern used by every VSO binding and
every first-class app.

- `auth/kubernetes/role/kes-vso` bound to SA `kes/kes`, policy `kes-keystore`,
  TTL 1h periodic.
- `kes-keystore` policy at `platform/manifests/openbao/policies/kes-keystore.hcl`:
  ```hcl
  path "secret/data/kes/keys/*" {
    capabilities = ["create", "read", "update", "delete"]
  }
  path "secret/metadata/kes/keys/*" {
    capabilities = ["read", "list", "delete"]
  }
  ```

| Alternative | Why rejected |
|---|---|
| AppRole (Role ID + Secret ID) | Static Secret ID needs storage; same pattern problem we just rotated away from with the seal transit token. |
| Static long-lived token | Same as AppRole, worse — single credential with no rotation story. |

#### 3. KES ↔ MinIO mTLS: cert-manager Certificates issued from `openbao-ca`

Both KES (server cert) and MinIO (client cert) get cert-manager-managed
Certificates from the existing `openbao-ca` Issuer (or a dedicated `kes-ca`
ClusterIssuer if we want crypto-separation).

- `kes-server-cert` → K8s Secret `kes-server-tls` (KES presents)
- `kes-client-cert` → K8s Secret `kes-client-tls` (MinIO mounts + presents)

cert-manager auto-rotates on the standard 60-day-before-expiry schedule.

#### 4. Migration plan: 9 steps, zero data loss

Execution order during the deploy session:

1. **Generate KES TLS material** via cert-manager (server + client Certificates).
2. **Write KES vault-keystore config** referencing OpenBao endpoint + the
   `kes-vso` k8s-auth role + the openbao-ca cert.
3. **Deploy KES Deployment + Service** in a new `kes` namespace.
4. **Import the existing MinIO master key** into KES at
   `secret/data/kes/keys/secforge-minio-key`. Value comes from the live
   `minio-kms-creds` K8s Secret (split `<name>:<base64>` → name=`secforge-minio-key`,
   base64=master key bytes). Done via `bao kv put` using the break-glass admin
   token on main openbao.
5. **Cut MinIO from static-KMS to KES**: replace `envFrom: minio-kms-creds`
   with `MINIO_KMS_KES_ENDPOINT=https://kes.kes.svc:7373`, `MINIO_KMS_KES_KEY_FILE`,
   `MINIO_KMS_KES_CERT_FILE`, `MINIO_KMS_KES_CAPATH`, `MINIO_KMS_KES_KEY_NAME=secforge-minio-key`.
   Restart MinIO Deployment.
6. **Verify backward compat**: read one object from each prefix (`cnpg/`,
   `member-hub-documents/`, `velero/`) — decryption must succeed under
   KES-proxied access to the same imported key.
7. **Generate v2 key** in KES: `kes key create secforge-minio-key-v2`.
   Switch bucket defaults: `mc encrypt set sse-kms local/<bucket> secforge-minio-key-v2`
   per bucket (writes use v2 going forward).
8. **Re-wrap existing objects**: `mc encrypt rotate local/<bucket>` per bucket.
   This re-wraps each object's DEK with v2 without re-encrypting the data
   itself. Fast for the ~33 GiB of existing objects.
9. **Delete v1 key** from KES: `kes key delete secforge-minio-key`.
   Historical state.db plaintext exposure of v1 is now dead.

#### 5. Greenfield rebuild ordering

KES adds a new layer between OpenBao and MinIO:

```
openbao-seal (shamir-sealed; operator unseals after host reboot)
  → openbao-{0,1,2} (transit-unsealed via openbao-seal)
  → KES (needs OpenBao for keystore reads)
  → MinIO (needs KES for KMS proxy)
  → CNPG WAL archiving + member-hub document writes + Velero backups
```

On a Hetzner box rebuild, KES must be deployed and reachable BEFORE MinIO
starts. The dependency is captured by an `initContainer` on MinIO that probes
`https://kes.kes.svc:7373/v1/ready` and waits.

## Consequences

### What this buys us

1. **In-place key rotation** — running `mc encrypt rotate` migrates all objects
   to a new master key without data loss. The MinIO SSE master key becomes a
   routinely-rotatable credential, not a one-shot secret.
2. **Per-bucket key separation** (future) — different buckets can use different
   master keys. `member-hub-documents` could have a tenant-scoped key separate
   from `cnpg/`, enabling more granular tenant isolation if we add per-tenant
   document keys later.
3. **KES audit trail** — every key access is logged by KES (separate from
   MinIO's audit log), giving forensic visibility into key usage.
4. **OpenBao-backed keystore** — KES doesn't hold key material on disk; OpenBao
   does. The existing seal-chain protects KES keystore.

### What this costs

1. **New platform component** — KES is one more thing to maintain, monitor,
   back up, and upgrade.
2. **Additional dependency** — MinIO now depends on KES which depends on
   OpenBao. The dependency chain grows by one hop.
3. **TLS material** — two more cert-manager Certificates, two more K8s Secrets.
4. **Greenfield runbook** — `docs/03-runbooks/cluster-rebuild.md` (when it
   exists) must place KES between OpenBao and MinIO.

### What this does NOT do

- **Does not solve the on-disk key problem** if attacker has both the disk and
  some way to unseal OpenBao. The trust root is still OpenBao + its seal chain.
- **Does not protect against root-on-running-box**. KES can mint key access
  for anyone with KES client cert (rendered into a K8s Secret), and kubectl
  exec into MinIO yields the cert. LUKS + a tighter SA boundary would close
  this; KES alone does not.
- **Does not retro-encrypt the old key value** that's in state.db kine history.
  That value is dead after step 9 of the migration, but until kine compacts and
  state.db is VACUUM'd, the historical bytes persist (low-risk: an attacker
  with state.db + an unsealed OpenBao + network access to MinIO API has
  everything they need without the master key at all).

## Open questions

1. **Dedicated `kes-ca` ClusterIssuer or reuse `openbao-ca`?** Reusing
   `openbao-ca` is simpler; dedicated CA cleanly separates trust boundaries.
   Default to reuse; revisit if KES has more clients than just MinIO.
2. **Key naming convention for rotation** — `secforge-minio-key-v1`,
   `-v2`, `-v3`? Or date-based (`-2026-05-28`)? Codify in the runbook.
3. **Per-bucket vs single key initially** — start with one key for all buckets
   (matches today), or seed with separate keys per bucket from day one?
   Recommendation: start with one, split when a real need (per-tenant
   isolation) arises.
4. **Backup story for KES keystore** — KES keys are in OpenBao, which is
   covered by Velero. So KES keystore is implicitly backed up. Verify in the
   greenfield rebuild drill (operator-backlog #64 Tier 2).

## Implementation plan

Tracked at operator-backlog **#70**. Estimated half-day of focused work split
into design (this ADR), provisioning (steps 1–5), and migration (steps 6–9).
The greenfield rebuild drill (#64) should be re-run after KES lands to confirm
the new ordering works from cold.
