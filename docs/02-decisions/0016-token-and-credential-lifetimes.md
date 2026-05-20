# ADR-0016: Token and credential lifetimes — canonical table

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

Token and credential TTLs are scattered across multiple architecture docs (Keycloak realm config in `01-iam-platform.md`, OpenBao auth/jwt TTL in `05-secrets-management.md`, SPIRE SVID lifetimes in `06-workload-identity.md`, BFF cookie TTL in `04-bff-pattern.md`). A future engineer choosing a cache TTL or a refresh window has to cross-reference five docs and hope none drifted.

Cache-TTL bugs from this kind of scatter are silent: a backend assuming a 12 h refresh window when the issuer says 30 m gets `invalid_grant` only on the first stale-token attempt; a CronJob assuming an SVID lasts 24 h when SPIRE rotates at 1 h misses the window mid-job. Compliance cutover (FedRAMP/CMMC mappings) requires this table to be authoritative.

This ADR establishes a single canonical table of every long-lived-enough-to-care-about credential the platform issues or holds, with the renewal mechanism and source-of-truth file.

## Decision

**All credential lifetimes are documented in the table below. Any deviation requires a new ADR superseding 0016.** When a TTL changes, the source-of-truth file changes AND this ADR changes (or is superseded). Drift between the two is treated as a defect.

### Canonical lifetimes table

| Credential | Issuer | TTL | Renewal mechanism | Source of truth |
|---|---|---|---|---|
| Keycloak access token (all realms) | Keycloak | 5 min | `refresh_token` grant | `01-iam-platform.md` realm config |
| Keycloak refresh token — `platform` realm | Keycloak | session-idle 15 min · remember-me 30 d | re-authentication | `01-iam-platform.md` |
| Keycloak refresh token — `secforge-tenants` realm | Keycloak | session-idle 30 min · no remember-me | re-authentication | `01-iam-platform.md` |
| Keycloak realm signing key (RS256) | Keycloak | 90 d | rotation runbook | [`docs/03-runbooks/realm-signing-key-rotation.md`](../03-runbooks/realm-signing-key-rotation.md) |
| SPIRE X.509-SVID | SPIRE Server | 1 h | auto-refresh by `spiffe-helper` / CSI driver | `06-workload-identity.md` |
| SPIRE JWT-SVID | SPIRE Server | 5 min | per-request fetch | `06-workload-identity.md` |
| OpenBao Transit-seal token | OpenBao seal-bao | 24 h, renewable | auto-renewal while main OpenBao is up | [ADR-0009](./0009-openbao-seal-strategy.md), [`openbao-recovery.md § Rotate the Transit unseal token`](../03-runbooks/openbao-recovery.md#rotate-the-transit-unseal-token) |
| OpenBao JWT-auth client token (per-app) | OpenBao | 1 h | re-auth via fresh JWT-SVID | `05-secrets-management.md` |
| OpenBao admin OIDC token | OpenBao | issuer (Keycloak) policy | re-auth | `infrastructure/openbao/configure-auth-oidc.sh` |
| BFF session cookie (Valkey TTL) | BFF + Valkey | idle 30 min · hard-cap 8 h | per-request renewal of idle | [ADR-0017](./0017-session-expiry-semantics.md), `04-bff-pattern.md` |
| DPoP key (per-pod, in-memory) | BFF | pod lifetime | n/a — pod restart mints a new key | [ADR-0011](./0011-bff-single-replica-local.md) |
| Wazuh internal mTLS leaf cert | Wazuh chart bootstrap | 5 y | (none today) — Phase 7d scheduled cert-manager replacement | `platform/values/wazuh.yaml`, [`docs/03-runbooks/wazuh-operations.md`](../03-runbooks/wazuh-operations.md) |
| Wazuh internal mTLS root CA | Wazuh chart bootstrap | 10 y | (none today) — see Phase 7c (SPIRE-as-CA) follow-up | as above |
| Image-signing key (Cosign, local) | operator | TBD — flagged in [F-ADR-12](../../Fix%20after%2007/00-audit-findings.md#f-adr-12--medium--missing-adr--image-signing-key-custody) | TBD operator decision before supply-chain phase | TBD |
| Wazuh dashboard admin password | apply.sh-generated | persistent until rotated | manual via apply.sh re-run | [`docs/03-runbooks/wazuh-operations.md § First login`](../03-runbooks/wazuh-operations.md#first-login) |
| Wazuh manager API password (`wazuh-wui`) | apply.sh-generated | persistent until rotated | manual via apply.sh re-run | as above |
| `wazuh-indexer-creds` (system pwd, not human-facing) | apply.sh-generated | persistent until rotated | manual via apply.sh re-run | as above |
| `wazuh-filebeat-creds` (system pwd, not human-facing) | apply.sh-generated | persistent until rotated | manual via apply.sh re-run | as above |

## Why these specific values

The full per-credential rationale lives in each source-of-truth file. This ADR captures only the deltas that aren't obvious from the row above:

- **Access token 5 min**: short enough that a stolen token's blast-radius window is small; long enough that refresh frequency doesn't dominate latency. Same as Keycloak's default; no override.
- **Realm signing key 90 d**: matches cert-manager's typical rotation window. 30-day rotation was considered and rejected as too noisy for a single-replica realm; 365-day was rejected as too long for an issuer-of-tokens.
- **SPIRE X.509-SVID 1 h vs JWT-SVID 5 min**: X.509-SVIDs are presented to ztunnel for mTLS; 1 h is the SPIRE default and balances refresh load vs. revocation responsiveness. JWT-SVIDs are presented to OpenBao at login and live only as long as the auth call needs them; 5 min is conservative for clock skew + network latency.
- **OpenBao Transit token 24 h**: Hashicorp default for transit-seal auth tokens. The renewable flag means a long-running cluster auto-extends; the cold-pause edge case is documented in [ADR-0009 follow-up + Phase 7d](./0009-openbao-seal-strategy.md).
- **BFF session 30-min idle / 8-h hard-cap**: 30-min idle matches the realm's session-idle for `secforge-tenants`; 8 h is a working-day ceiling. Both are the BFF's enforcement ceiling; Keycloak refresh-token expiry catches the user first if their refresh token expired earlier.
- **DPoP key per-pod-lifetime**: documented in [ADR-0011](./0011-bff-single-replica-local.md). Cloud edition revisits with Valkey-stored per-session keys.
- **Wazuh internal mTLS 5-year leaf, 10-year root**: chart default. These are component-internal certs (not user/session credentials) — distinct threat model from the CLAUDE.md long-lived-credential bright-line. Cloud migration replaces via cert-manager + 90-day rotation alongside Phase 7c (SPIRE-as-CA cutover); local edition accepts the long TTL as a known residual risk.
- **Image-signing key**: explicitly TBD because key custody is a real ops decision with multiple acceptable answers (file-based local, HSM, KMS, tied to GitHub Actions OIDC). [F-ADR-12](../../Fix%20after%2007/00-audit-findings.md#f-adr-12--medium--missing-adr--image-signing-key-custody) flags this as needing operator input before the supply-chain phase runs.

## Cross-references

This table is referenced from:
- [`CLAUDE.md`](../../CLAUDE.md) — Architecture stack section
- [`docs/01-architecture/01-iam-platform.md`](../01-architecture/01-iam-platform.md) — Keycloak rows
- [`docs/01-architecture/05-secrets-management.md`](../01-architecture/05-secrets-management.md) — OpenBao rows
- [`docs/01-architecture/06-workload-identity.md`](../01-architecture/06-workload-identity.md) — SPIRE rows
- [`docs/01-architecture/04-bff-pattern.md`](../01-architecture/04-bff-pattern.md) — session + DPoP rows
- [`docs/01-architecture/08-observability.md`](../01-architecture/08-observability.md) — Wazuh rows

When any of those files changes a TTL, this ADR is updated in the same edit.

## Re-evaluation triggers

- A new Phase introduces a credential class not in the table → add a row.
- A compliance regime mandates a different TTL ceiling (e.g. FedRAMP wants ≤ 5 min for access tokens — already met) → confirm row, supersede if needed.
- An incident reveals a TTL was load-bearing in a way the rationale didn't anticipate → supersede with a new ADR + a migration plan; do not silently edit this one.

## References

- [ADR-0009](./0009-openbao-seal-strategy.md) — OpenBao seal strategy
- [ADR-0011](./0011-bff-single-replica-local.md) — BFF per-pod DPoP key constraint
- [ADR-0017](./0017-session-expiry-semantics.md) — session expiry semantics (companion ADR)
- [Fix after 07 § F-ADR-2](../../Fix%20after%2007/00-audit-findings.md#f-adr-2--high--token--credential-lifetimes-scattered-no-consolidated-source) — the audit finding this ADR closes
