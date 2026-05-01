# ADR-0017: Session expiry semantics — Valkey-authoritative, no cookie Max-Age

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

The BFF's session cookie design (`docs/01-architecture/04-bff-pattern.md` line 84) deliberately leaves the cookie's `Max-Age` and `Expires` attributes UNSET. The cookie is a session cookie in browser terms (cleared on browser close); the persistence story is entirely in Valkey, with an idle timeout of 30 min and a hard cap of 8 h.

This is a non-obvious design choice. The "fix" a future engineer would reach for — "users are getting logged out unexpectedly, set Max-Age=24h" — silently breaks the model: a cookie with `Max-Age` set will outlive its Valkey TTL, which means the next request after Valkey expiry sends a stale cookie that resolves to no session, and the BFF returns 401. The user sees "logged out" and re-logs in. The cookie's `Max-Age` did not buy them a longer session — the ENGINE's TTL is the source of truth.

This ADR locks in the design and documents the failure mode it produces (silent 401 → re-login) so future engineers don't pattern-match against the wrong fix.

## Decision

The BFF session cookie:
- **`Max-Age` is UNSET** and **`Expires` is UNSET**. The cookie is a session cookie at the browser level; its lifetime is "browser closes."
- **`HttpOnly`, `Secure`, `SameSite=Lax`** are set unconditionally.
- **`Path=/`** so all routes share the session.
- **Cookie value is opaque**: a 256-bit random ID. The session payload (access token, refresh token, ID token, user `sub`, DPoP key thumbprint at issue) lives in Valkey under that key.

The Valkey session entry:
- **Idle timeout: 30 min.** Reset on every authenticated request handler that touches the session.
- **Hard cap: 8 h.** Set at session-creation time as `max-lifetime` metadata; no request extends past this.
- **Storage**: `bff:session:<id>` key, JSON payload, TTL set via Valkey `EXPIRE` per-request.

## Failure mode (and how the BFF handles it)

When a request arrives with a session cookie whose Valkey entry has expired:

1. BFF reads cookie, looks up Valkey, gets nil.
2. BFF clears the cookie (`Set-Cookie` with `Max-Age=0`).
3. BFF emits a `Location: /login` redirect (302).
4. User's browser follows; the OIDC PAR + DPoP auth-code flow re-runs.
5. New session is created.

The user-visible behavior is "I'm asked to log in again." This is intentional — sessions ARE a security boundary. The BFF MUST NOT silently extend a session past its TTL by re-issuing a fresh cookie with the same opaque ID; that defeats the whole point of having a TTL.

## What MUST NOT change without superseding this ADR

- Adding `Max-Age` or `Expires` to the cookie.
- Persisting the session payload in the cookie itself (the cookie MUST stay opaque; payload MUST stay in Valkey).
- Extending Valkey TTL on idle by more than 30 min on a single request.
- Lifting the 8-h hard cap.

Any of these creates one of three failure modes:
- Browser-stored payload becomes a credential-theft target if the cookie is exfiltrated (mitigated only by HttpOnly + Secure + DPoP-binding, all of which are necessary but the cookie-stays-opaque rule is structural).
- Cookie outliving Valkey TTL surfaces as a "logged out unexpectedly" UX bug that engineers fix the wrong way (extending cookie Max-Age).
- Lifting the hard cap removes the working-day ceiling that the threat model relies on (a session that never expires is a session whose theft has unbounded blast radius).

## Why these specific values

- **30-min idle**: matches the `secforge-tenants` realm's `Session Idle Timeout`. Symmetric so the user's experience is consistent — whether the session expires server-side first (Valkey) or issuer-side first (Keycloak refresh token), the failure is the same.
- **8-h hard cap**: a working-day ceiling. Long enough that a typical user doesn't get re-prompted mid-day; short enough that an unattended laptop can't be exploited indefinitely. Matches CLAUDE.md's bright-line rule against >24-h session credentials.
- **HttpOnly + Secure + SameSite=Lax**: standard hardening for session cookies. SameSite=Strict was considered and rejected — the OIDC redirect-back-from-Keycloak flow needs Lax to preserve the session cookie on cross-origin GET.
- **DPoP-bound at issue**: the DPoP key thumbprint stored in the Valkey payload at session creation MUST match the DPoP proof on every subsequent request from this session. Pod restart mints a new DPoP key, which means the user's next request from a pre-restart session fails DPoP validation → 401 → relogin (same flow as above). [ADR-0011](./0011-bff-single-replica-local.md) accepts this for the local single-replica edition.

## Cross-references

- [ADR-0011](./0011-bff-single-replica-local.md) — single-replica BFF + per-pod DPoP key
- [ADR-0016](./0016-token-and-credential-lifetimes.md) — canonical TTL table including the BFF session row
- [`docs/01-architecture/04-bff-pattern.md`](../01-architecture/04-bff-pattern.md) — session storage + cookie design

## Re-evaluation triggers

- Cloud-edition multi-replica BFF: shared DPoP-key story changes; session lifecycle may shift to per-session keys in Valkey. Revisit alongside [ADR-0011](./0011-bff-single-replica-local.md) follow-up.
- A real-user UX complaint that the 30-min idle is unacceptably short: tune the realm AND this ADR's value AND `04-bff-pattern.md` in one edit; do not split.
- A compliance regime that mandates a different idle ceiling: confirm or supersede.

## References

- [ADR-0011](./0011-bff-single-replica-local.md)
- [ADR-0016](./0016-token-and-credential-lifetimes.md)
- [Fix after 07 § F-ADR-8](../../Fix%20after%2007/00-audit-findings.md#f-adr-8--medium--missing-adr--session-expiry-semantics) — the audit finding this ADR closes
