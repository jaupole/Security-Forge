# ADR-0007: TOTP (Software Authenticator) as Primary Factor for Local-Edition Realms; Defer Passkeys/Hardware FIDO2 Until Production Hardening

**Status**: Accepted
**Date**: 2026-04-29
**Decision-makers**: Project owner
**Supersedes (for the local-dev window)**: [ADR-0002 — Use Windows Hello as the Local-Edition Admin Passkey](./0002-local-passkey-via-windows-hello.md)

## Context

[ADR-0002](./0002-local-passkey-via-windows-hello.md) committed to Windows Hello (TPM-backed platform passkey) as the admin authenticator for the local edition, with hardware FIDO2 keys deferred until migration. That decision rested on the assumption that Windows Hello WebAuthn would work end-to-end for the project owner's setup.

In practice, the owner is building this platform on a Windows host running Docker Desktop with Kubernetes accessed via WSL2, and explicitly stated that no hardware FIDO2 keys are available for the development phase. Validating the auth flow with passkeys (Windows Hello included) before any other end-to-end testing has happened introduces a single point of failure in the development experience: if Windows Hello WebAuthn ceremony fails on this specific Windows + browser + Keycloak combination, the entire login flow is blocked and Phase 3 cannot complete.

The owner asked to validate the auth flow with **TOTP (software authenticator app — Google Authenticator, Authy, 1Password TOTP, etc.)** first, as an interim factor, with the understanding that the project will revert to passkeys before any production-style hardening or non-local exposure.

## Decision

**For the local edition only, configure both `platform` and `secforge-tenants` realms with TOTP as the primary authentication factor and Keycloak's recovery-codes as the secondary recovery factor. Do not configure WebAuthn / passkeys as part of the active flow during the local-dev window.**

Concretely:

| Realm | Primary | Recovery | Forbidden |
|---|---|---|---|
| `platform` | TOTP (RFC 6238, SHA-1, 6 digits, 30s) | 10 single-use recovery codes generated at TOTP enrollment | passkey/WebAuthn (not configured), SMS, push |
| `secforge-tenants` | TOTP (same params) | 10 single-use recovery codes generated at TOTP enrollment | passkey/WebAuthn (not configured), SMS, push |

A bootstrap admin user with a randomly-generated password lives in the `master` realm only; it is used once to seed the platform realm's first human user and is deleted afterward.

The Keycloak server's `--features=recovery-codes` flag is enabled to expose the `recovery-authn-codes` required action and authenticator. Users see "Set up TOTP" and "Generate Recovery Codes" as required actions on first login, in that order. The 10 codes are displayed once at generation; users are instructed to store them in a password manager.

This decision is **interim** and is reversed before the platform reaches any of the triggers in the "Reversal" section below.

## Rationale

### Why TOTP is acceptable for local development

The threat model for a single developer's local laptop is:

- **In-scope**: accidental exposure (e.g., a misconfigured port-forward), shoulder-surfing, simple credential reuse.
- **Out of scope**: targeted phishing of the developer's own credentials, real-time relay attacks, supply-chain compromise of the Keycloak realm.

TOTP defends against the in-scope threats: it requires possession of the user's phone in addition to anything stolen from the password store. It does not defend against the out-of-scope threats — but neither do they apply at the local-development blast radius.

### Why passkeys/WebAuthn remain the architectural target

Passkeys (FIDO2/WebAuthn) are origin-bound: a phisher cannot relay credentials in real time because the browser refuses to assert against a wrong origin. TOTP, by contrast, is phishable via a real-time relay (the attacker hosts a fake login page, the user types the 6-digit code, the attacker uses it within 30 seconds against the real Keycloak). This is a meaningful threat the moment users other than the project owner exist, the moment the platform is reachable from outside loopback, or the moment real production data lives in it. The architecture commitment to passkeys does not change; only the *interim* during the single-developer local phase does.

### Why recovery codes instead of email-link or admin-reset

- **Email-link recovery**: phishable; requires a working SMTP path; couples auth recovery to email custody. Rejected.
- **SMS**: forbidden by CLAUDE.md, by every credible security guideline since 2017, and by basic honesty. Rejected.
- **Admin-reset only**: works for the project owner ("I'll just delete the user and remake it"), fails for tenant users ("the platform owner has to be paged at 3am because I dropped my phone"). Recovery codes solve the lockout problem with a self-service path that doesn't add a phishable channel.

Ten codes is the Keycloak default and the de-facto standard for this pattern. Single-use plus single-display is the operational expectation.

### Why we don't run *both* TOTP and passkey simultaneously

We could enable both and let users pick. We don't, because:
- It dilutes the muscle memory of the operational procedures (which factor is the recovery factor?).
- It opens an authentication-strength downgrade pathway: if passkey is broken/lost, the user falls back to TOTP, which is weaker — and an attacker can force the downgrade by attriting the stronger factor first.
- The point of this ADR is that the local window is *cheap* and we should keep it simple. When we reverse the ADR and re-enable passkeys, we will *replace* TOTP, not coexist with it.

## Alternatives considered and rejected

### Stay on Windows Hello (ADR-0002 unchanged)

**Pros**: matches the architecture commitment exactly; no ADR needed.
**Cons**: validating WebAuthn end-to-end on this Windows + WSL2 + browser + mkcert + Keycloak combination is a multi-variable troubleshooting exercise; failure on any one variable blocks Phase 3 indefinitely. The owner explicitly chose to defer that work.
**Decision**: rejected for the local-dev window only.

### Phone-based passkey (iCloud Keychain / Google Password Manager) for local

**Pros**: passkey ergonomics; no hardware key purchase.
**Cons**: cross-device passkey ceremony from a Windows host requires QR-code-based hybrid transport, which is the most fragile part of the WebAuthn stack and would not exercise the eventual production passkey path (where laptop-resident or hardware-resident passkeys are the norm).
**Decision**: rejected.

### Password-only (with strong password policy)

**Pros**: trivial.
**Cons**: passwords without a second factor are below the floor of "values security over convenience" stated in CLAUDE.md. Phishable, brute-forceable, reusable.
**Decision**: rejected. Password is permitted as a *bootstrap-only* mechanism for the master-realm admin and is deleted as soon as the human admin's TOTP is enrolled.

## Consequences

### What this commits us to

- Phase 3.4 realm import sets `otpPolicyType: totp`, `otpPolicyAlgorithm: HmacSHA1`, `otpPolicyDigits: 6`, `otpPolicyPeriod: 30`, `otpPolicyLookAheadWindow: 1`.
- `requiredActions` includes `CONFIGURE_TOTP` (enabled, default-action) and `CONFIGURE_RECOVERY_AUTHN_CODES` (enabled, default-action).
- The default browser flow is customized so OTP is REQUIRED at every login (not the default "Conditional OTP" which only prompts if the user has OTP set up).
- `--features=recovery-codes` is enabled on the Keycloak server (build-time).
- WebAuthn / passkey policies are NOT configured in the realms (no `webauthnPolicy` block in realm import). They are added back as part of the reversal procedure.

### What this does NOT change

- BFF-side OAuth flow (PAR + DPoP + PKCE + refresh-token-rotation) is unaffected by which authenticator factor Keycloak uses to authenticate the human; that's an internal Keycloak concern.
- Application code is unaffected.
- Migration playbooks already require hardware FIDO2 key registration before cutover; this ADR adds one extra line to those playbooks ("revert ADR-0007 — re-enable passkey policy on both realms").

## Reversal trigger

This ADR is reversed (TOTP downgraded to recovery-only or removed; passkeys + hardware FIDO2 promoted to primary) when **any** of the following becomes true:

1. Following either migration playbook (VPS or AWS).
2. Any user other than the project owner is given a role of any kind in any realm beyond `master`.
3. The platform is reachable from any network beyond the developer machine's loopback / local LAN.
4. Real production-classified data is loaded into any backing store.
5. The project owner acquires hardware FIDO2 keys and chooses to migrate ahead of (1)–(4).

When the trigger fires, the reversal is:

1. Update both realms' `webauthnPolicy` per [ADR-0002](./0002-local-passkey-via-windows-hello.md): `signatureAlgorithms: [ES256, RS256]`, `userVerificationRequirement: required`, `attestationConveyancePreference: none` (or `direct` if hardware keys are mandatory).
2. Configure the browser flow to require WebAuthn authentication before OTP/password.
3. Add `webauthn-register` and `webauthn-register-passwordless` to `requiredActions`.
4. Enroll hardware FIDO2 keys for every existing user (or force re-enrollment via required action).
5. Demote TOTP to a recovery-only factor (or remove entirely from the active flow).
6. Re-evaluate session lifetimes given the stronger primary factor.
7. Update `iam-platform.md` and PLAN.md.

## References

- [ADR-0002](./0002-local-passkey-via-windows-hello.md) — superseded for the local-dev window; reversal target.
- [docs/01-architecture/01-iam-platform.md](../01-architecture/01-iam-platform.md) — current realm configuration.
- [CLAUDE.md](../../CLAUDE.md) — "values security over convenience" mission, SMS forbidden, OAuth 2.1 baseline.
- RFC 6238 (TOTP): <https://datatracker.ietf.org/doc/html/rfc6238>
- Keycloak OTP / authenticator policy: <https://www.keycloak.org/docs/latest/server_admin/#one-time-password-otp-policies>
- Keycloak recovery codes: <https://www.keycloak.org/docs/latest/server_admin/#con-recovery-codes_server_administration_guide>
