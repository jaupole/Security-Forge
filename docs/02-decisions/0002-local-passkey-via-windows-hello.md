# ADR-0002: Use Windows Hello as the Local-Edition Admin Passkey; Defer Hardware FIDO2 Keys Until Pre-Deployment

**Status**: Superseded for the local-dev window by [ADR-0007](./0007-totp-instead-of-passkeys-locally.md) (2026-04-29). The reversal triggers and migration steps in ADR-0007 restore this ADR's posture (Windows Hello / passkeys) before any non-local exposure.
**Original status**: Accepted (2026-04-28)
**Date**: 2026-04-28
**Decision-makers**: Project owner
**Supersedes / amends**: Section "Hardware FIDO2 keys" guidance in [docs/99-archive/00-getting-started/01-prerequisites.md](../99-archive/00-getting-started/01-prerequisites.md)

## Context

The architecture (CLAUDE.md, stack table) commits to "passkeys + hardware keys for admin." The original prerequisites document instructed the owner to order two hardware FIDO2 keys (Token2 PIN+, YubiKey 5, or SoloKey v2) before Phase 3 (Keycloak).

The owner is building the platform single-developer, locally on Docker Desktop Kubernetes (see [ADR-0001](./0001-local-first.md)), and asked whether hardware key procurement could be deferred until the platform is ready to be deployed beyond the local machine.

## Decision

**For the local edition, use Windows Hello (TPM-backed platform passkey) as the admin WebAuthn factor. Defer hardware FIDO2 key procurement until the migration-out-of-local trigger fires.**

The Keycloak WebAuthn policy will be configured to accept both platform and cross-platform authenticators, so the migration to hardware keys requires no policy or code changes — only credential registration.

## Rationale

### Windows Hello satisfies the security properties that matter for local use

| Property | Windows Hello | Hardware FIDO2 key | Required locally? |
|---|---|---|---|
| FIDO2 / WebAuthn protocol | ✅ | ✅ | yes |
| Origin-bound (phishing-resistant) | ✅ | ✅ | yes |
| Private key in tamper-resistant hardware | ✅ (TPM) | ✅ | yes |
| User verification (PIN / biometric) | ✅ | ✅ | yes |
| Portable across devices | ❌ | ✅ | **no** (single dev machine) |
| Survives PC loss / reinstall | ❌ | ✅ | **no** (no production data) |
| AAL3 attestation chain | ⚠️ TPM-dependent | ✅ FIDO L1 | **no** (no compliance scope) |

The properties Windows Hello lacks (portability, recovery, attestation) are not needed while the platform runs on a single developer machine with no production data and no users beyond the owner.

### The architecture stays unchanged

Keycloak's WebAuthn policy will be configured once and accept both authenticator types:
- `User Verification: required` — forces PIN or biometric, not just user presence
- `Attestation Conveyance: none` — Windows Hello attestation chains are inconsistent; tightening this is the migration trigger
- `Authenticator Attachment: not specified` — allows both platform (Windows Hello) and cross-platform (USB security keys)
- `Resident Key: required` — true passkeys, not legacy second-factor

A YubiKey or Token2 PIN+ plugged in later registers under the same policy with no reconfiguration.

### Break-glass account is non-negotiable, locally too

Even with Windows Hello working, the owner must provision a separate break-glass admin account from day one:
- Long random password (≥32 chars) stored in an offline password manager
- TOTP as second factor, seed printed and stored physically
- Used only when the primary WebAuthn path fails (Windows reinstall, TPM clearing, PC death)

This is required regardless of which passkey factor is in use, and matches what production deployment will require anyway.

## Alternatives considered and rejected

### Order hardware keys now and wait for shipping (the original plan)

**Pros**: matches the architecture commitment exactly; no ADR needed.
**Cons**: blocks Phase 3 progress on shipping time; ~$50 spend before any local validation.
**Decision**: rejected for local edition only. Reinstated as a hard requirement at the migration trigger.

### Use TOTP / push apps as the admin factor

**Pros**: cheapest; no hardware needed.
**Cons**: not phishing-resistant (no origin binding); push apps vulnerable to MFA fatigue. Violates the spirit of the project's "values security over convenience" mission. Would require changing Keycloak policy at migration time, not just adding a credential.
**Decision**: rejected. Builds the wrong muscle memory.

### Use a phone-based platform passkey (iCloud Keychain / Google Password Manager)

**Pros**: works; satisfies WebAuthn; portable across the user's own devices.
**Cons**: introduces a third-party sync service into the trust path for the local admin credential. Adds setup friction (cross-device passkey ceremony from a Windows PC requires QR-code-based hybrid transport).
**Decision**: rejected for the *primary* local credential. Acceptable as an additional registered passkey if the owner wants it.

## Consequences

### What this commits us to

- Phase 3 Keycloak configuration must use the policy values listed above and **must not** enforce attestation conveyance.
- A break-glass account is provisioned in Phase 3, with credentials stored offline, before the owner registers Windows Hello as the primary factor.
- The migration playbooks ([migration-to-vps.md](../99-archive/migration-to-vps.md), [migration-to-aws.md](../99-archive/migration-to-aws.md)) include a dedicated step to register hardware FIDO2 keys and tighten the WebAuthn policy *before* the platform is exposed beyond the local network.

### What this does not change

- The committed architecture stack ("passkeys + hardware keys for admin") is unchanged for any non-local deployment.
- Application-user passkey flows are unaffected — users authenticate with their own platform passkeys (Windows Hello, Touch ID, Android biometric) on their own devices, exactly as they would in production.

## Reversal trigger

This ADR is reversed (i.e., hardware keys become required) the moment **any** of the following becomes true:

1. Following either migration playbook (VPS or AWS) — hardware keys must be in hand and registered before cutover.
2. Any user other than the project owner is given an admin role in the platform.
3. The platform is reachable from any network beyond the developer machine's loopback / local LAN.
4. Real production-classified data is loaded into the platform.

When the trigger fires, the migration is roughly:
1. Order two hardware keys (Token2 PIN+ recommended for cost).
2. Log into Keycloak with Windows Hello.
3. Account → Security → register both hardware keys.
4. Tighten WebAuthn policy: `Attestation Conveyance: direct`, optionally `Authenticator Attachment: cross-platform` for the admin role.
5. Optionally remove the Windows Hello credential, or keep it as a tertiary factor on the developer machine only.

## References

- [CLAUDE.md](../../CLAUDE.md) — stack-table commitment to "passkeys + hardware keys for admin."
- [ADR-0001](./0001-local-first.md) — local-first decision that this ADR amends.
- [docs/99-archive/00-getting-started/01-prerequisites.md](../99-archive/00-getting-started/01-prerequisites.md) — section 6, which now points at this ADR.
- [docs/99-archive/migration-to-vps.md](../99-archive/migration-to-vps.md) — VPS migration playbook (includes hardware-key registration step).
- [docs/99-archive/migration-to-aws.md](../99-archive/migration-to-aws.md) — AWS migration playbook (includes hardware-key registration step).
