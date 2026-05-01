# ADR-0006: Keycloak Realm Signing Keys (Local Edition)

**Status**: Accepted
**Date**: 2026-04-29
**Decision-makers**: Project owner

## Context

Each Keycloak realm signs its access tokens, ID tokens, and (when applicable) SAML assertions with its own keypair. Token consumers (BFFs, resource servers) verify those signatures by fetching the realm's JWKS and trusting the published `kid`. The keypair's custody model is therefore the realm's only line of defense against issuer forgery: anyone who exfiltrates the active private key can mint tokens that resource servers will accept as legitimately issued.

In the **cloud edition** the architecture commits to AWS KMS via PKCS#11 for realm signing keys: the private key never exists in plaintext outside the HSM, Keycloak performs sign operations through `kc.sh start --features=pkcs11-keys`, and rotation is a KMS-side operation. This is the recommended posture for any deployment that issues tokens to anything other than the developer's own laptop.

In the **local edition** there is no KMS. The available custody options are:

1. **Keycloak's built-in key provider** — generates RS256/PS256 keys, stores them in the realm's Postgres backing store, and uses Keycloak's master encryption key to encrypt-at-rest. Default behavior; no special configuration required.
2. **mkcert local CA as a PKI provider** — generate keypairs externally, import as a `rsa` key provider with manual lifecycle. Adds operational burden and yields no security improvement, since the keys still end up in Postgres.
3. **OpenBao Transit** — sign through a hosted KMS-equivalent. Available in principle, but introduces a dependency cycle (Phase 5 OpenBao authenticates workloads via SPIRE → SPIRE has its own root in a Secret, not in OpenBao). Rejected for the same dependency reason as in [ADR-0005](./0005-spire-architecture-local.md).

## Decision

**For the local edition, we use Keycloak's built-in key provider with RS256 (and PS256 available for clients that prefer it). Keys live in the realm's Postgres database, encrypted by Keycloak's master encryption key.**

Configuration applied to both `platform` and `secforge-tenants` realms:

| Setting | Value |
|---|---|
| Algorithm | RS256 (active), PS256 (advertised in JWKS) |
| Active key priority | 100 |
| Key size | 2048 bits |
| Key rotation cadence | 90 days |
| Overlap window | 30 days (active + previous keys both publish in JWKS during overlap) |
| HS256 | **disabled** for client tokens (HMAC keys exist for internal cookie signing only) |

The 30-day overlap is the verification window: any access token issued under the previous key remains valid for verification until the access token's own lifetime (5 minutes) expires; the overlap is generous so refresh-token rotation completes cleanly across a key change.

## Rationale

### Why not just defer until cloud migration

We could leave the realm with whatever Keycloak generates by default and document the gap. The reason we configure it explicitly:

- **Algorithm and HMAC posture are realm-wide policy decisions, not migration-time tweaks.** RS256/PS256 vs. HS256 affects every client; tightening it later means re-issuing every client. We set this once, now.
- **Rotation cadence builds operational muscle memory.** The 90-day rotation runbook ([realm-signing-key-rotation.md](../03-runbooks/realm-signing-key-rotation.md)) is exercised at least once during the local-edition lifetime so we know the procedure works before any production user depends on it.

### Why RS256 active and PS256 in JWKS

RS256 is universally supported. PS256 is RSA-PSS, structurally similar but with non-deterministic padding (`MGF1`) — preferred by some auditors. We publish both so a future BFF or resource server can opt into PS256 without a realm-config change. The active key on the realm signs with RS256; PS256 is only used if a client requests it via `id_token_signed_response_alg`.

### Why not HS256

HS256 implies a shared secret between issuer and verifier. We do not share secrets between Keycloak and BFFs — verifiers fetch JWKS over HTTPS. HS256 in JWT libraries has been the source of "alg=none" / "alg confusion" bugs for years; the cheapest defense is "this realm does not advertise HS256 for client-bound tokens." (Keycloak still uses HS256 internally for some session/cookie signing; that's separate and unavoidable.)

### Why 2048-bit RSA, not 3072 or 4096

RS256/PS256 with 2048-bit keys is the floor for current best-practice (NIST sec strength ~112 bits). 3072+ buys margin against a future quantum-relevant cryptanalysis improvement but quadruples sign cost. We pick 2048 for the local edition; the migration playbook reconsiders this when keys move to KMS (which makes 3072+ free at the per-sign level).

## Alternatives considered and rejected

### `mkcert` as an external key provider

`mkcert` is a CA — it issues server certs. It does not solve the "realm signing key custody" problem. Importing a keypair from `mkcert` into Keycloak's `rsa` provider stores the same key material in the same Postgres in the same way; we'd just add a manual lifecycle step. Rejected.

### Generate keys externally with `openssl`, mount as Secret

Same end state as the previous alternative — keys land in Keycloak's DB after import. The marginal difference is that the original key file exists transiently on the developer's disk, where it shouldn't. Rejected.

### OpenBao Transit signing

Possible, but Phase 5 hasn't run yet and would create a dependency cycle (SPIRE bootstrap and OpenBao bootstrap both expect the other to provide trust). Rejected on dependency grounds; revisit in cloud migration alongside the KMS swap, where AWS KMS is the natural answer anyway.

### Skip rotation entirely, rotate only at migration

Rejected. A key that has never been rotated is a key whose rotation procedure is untested. Failing a rotation in the cloud during a real incident, with no prior practice, is a worse failure mode than rotating routinely on the local cluster where blast radius is one developer.

## Consequences

### What this commits us to

- The realm-import manifests (Phase 3.4) must include a `rsa-generated` and `rsa-enc-generated` component with `priority: 100` and `keySize: 2048`. They must NOT include an `hmac-generated` component for client-bound tokens (Keycloak's master HMAC is unrelated and stays).
- HS256 must not appear in any realm's `id_token_signing_alg_values_supported` for client clients we register. The realm-level discovery doc may still advertise HS256 (it's a realm-wide list); the per-client `idTokenSignatureAlg` field forces RS256 or PS256.
- A 90-day-cadence rotation runbook is followed.
- A 30-day overlap is honored at every rotation: the previous key stays in JWKS as `passive` for 30 days after the new key takes priority, then is deleted.

### What this does NOT change

- The Keycloak Operator and the realm CR shape stay identical to cloud. Migrating to KMS is a per-realm component swap (`rsa-generated` → `pkcs11`) plus a feature flag (`--features=pkcs11-keys`).
- Token verifiers (BFFs, resource servers) continue to discover keys via JWKS, exactly as they will in cloud. Nothing in their code changes at migration.

### Known local gaps

1. **Keys are in Postgres.** Anyone with `psql` access can read the encrypted blobs; anyone with the master encryption key can decrypt them. The master key itself lives in Keycloak's environment (default behavior). This is the gap that KMS closes; it stays open until cloud migration.
2. **No `OperatorConditionsBundle` for KMS migration.** When we migrate, we'll cut over with a fresh keypair generated in KMS (overlap-rotate), not by importing the existing key into KMS. Accept the one-time JWKS churn.

## Reversal trigger

This ADR is reversed (i.e., KMS-backed keys become required) when **any** of the following becomes true:

1. The platform is exposed beyond loopback / LAN.
2. Real production-classified data is loaded.
3. Users other than the project owner depend on tokens issued by these realms.
4. A migration playbook (`migration-to-vps.md`, `migration-to-aws.md`) is followed — the migration playbook explicitly fires this reversal.

Migration steps (when triggered):

1. Provision an AWS KMS key (or GCP Cloud KMS / Azure Key Vault equivalent) per environment.
2. Add `--features=pkcs11-keys` to the Keycloak CR's features list.
3. Add a `pkcs11` key provider component to each realm with `priority: 200` (higher than the existing `rsa-generated:100`).
4. Wait at least 5 minutes (one access-token TTL) for the new key to propagate.
5. Set the existing `rsa-generated` component to `enabled: false, active: false` (`passive`); leave it for 30 days for token verification.
6. After 30 days, delete the `rsa-generated` component.
7. Delete the encrypted key blobs from Postgres if any token still references them (optional cleanup).

## References

- [docs/01-architecture/01-iam-platform.md](../01-architecture/01-iam-platform.md) — IAM platform architecture.
- [docs/03-runbooks/realm-signing-key-rotation.md](../03-runbooks/realm-signing-key-rotation.md) — 90-day rotation procedure.
- [ADR-0001](./0001-local-first.md) — local-first decision this ADR sits under.
- Keycloak key provider docs: <https://www.keycloak.org/server/keys>
- RFC 8017 (RSA-PSS / PS256): <https://datatracker.ietf.org/doc/html/rfc8017>
