# ADR-0036: Production authentication factors — passkeys

**Status**: Accepted
**Date**: 2026-06-07 (records the production posture reached 2026-05-14 / 2026-05-27)
**Decision-makers**: operator
**Supersedes**: the interim posture of [ADR-0007](./0007-totp-instead-of-passkeys-locally.md)

## Context

ADR-0007 chose TOTP as the interim primary second factor for the *local edition* realms and
explicitly deferred passkeys / hardware FIDO2 to "production hardening," with a revert clause: when
the platform runs on real TLS at `*.secforge.dev`, flip to WebAuthn. Production now runs on real
Let's Encrypt TLS, so WebAuthn (passkeys) works natively, and the flip has happened. This ADR
records the production factor posture so the docs no longer claim TOTP.

## Decision

Production uses **passkeys (WebAuthn)** as the platform's authentication factor, with a per-realm
posture (RpId `secforge.dev`, which covers all subdomains). **TOTP is removed.**

- **`platform` realm (operators / admins)** — browser flow `browser-webauthn-required`: password
  **and** a registered passkey are both required; `webauthn-register` is a default required action;
  recovery codes are retained as the fallback factor.
- **`secforge-tenants` realm (tenants / members)** — browser flow `browser-flexible`: password
  **or** passkey as the first factor, with optional 2FA; no recovery codes. This is deliberately
  lighter than the operator realm to fit a broad tenant audience.

## Rationale

Passkeys are phishing-resistant and work over real TLS on `*.secforge.dev`; TOTP was only ever the
interim choice while the local edition lacked a trusted cert. Operators hold the keys to the
platform, so their realm enforces a mandatory passkey on top of a password. Tenants need a low-
friction path, so their realm accepts password-or-passkey and leaves 2FA optional.

## Alternatives considered and rejected

- **Keep TOTP.** Rejected — phishable, and the interim condition (no trusted cert) no longer holds.
- **Mandatory passkey for tenants too.** Rejected for now — too much enrollment friction for a
  broad member audience; revisit if tenant data sensitivity rises.
- **SMS / email OTP.** Rejected — SMS as an MFA factor is a bright-line "never" for this platform.

## Consequences

- The realm-import manifests encode both browser flows; the custom Keycloak image bakes the WebAuthn
  policy and required actions. See the keycloak realm-import codification and
  [keycloak-operations.md](../03-runbooks/keycloak-operations.md).
- Recovery codes exist only in the `platform` realm; tenant recovery is operator-assisted.
- Reverting a realm to TOTP would be a regression and should not happen without a new ADR.

## Re-evaluation criteria

Revisit if a compliance regime requires hardware-bound FIDO2 (AAL3) for tenants, or if passkey
enrollment friction measurably blocks tenant onboarding.

## References

- [ADR-0007 — TOTP as primary factor (local edition, superseded posture)](./0007-totp-instead-of-passkeys-locally.md)
- [ADR-0002 — Windows Hello as local admin passkey (superseded by 0007)](./0002-local-passkey-via-windows-hello.md)
