# Migration: Keycloak → AWS Cognito (compliance-cutover playbook)

> **Status:** forward-looking reference. AWS Cognito is the current first-pick compliance-time IdP because of its FedRAMP authorizations; the same pattern applies to any OIDC-compliant managed IdP (Okta, Auth0, Ping). This doc exists to make the operator's "easy compliance transition" promise inspectable: you can read it today and know what changes (and what doesn't).
>
> Companion: [migration-to-aws.md](./migration-to-aws.md) (cluster-level AWS migration), [migration-to-vps.md](./migration-to-vps.md) (single-VPS staging path).

The platform's OIDC architecture is intentionally vendor-neutral at the API edge: every first-class app reads identity through the `apps/lib/oidc.Provider` interface ([Fix-after-07 §A.2](../../Fix%20after%2007/01-fix-prompt.md), [ADR-0014](../02-decisions/0014-api-auth-library-design.md)). The Keycloak-specific bits (DER-SHA256 `kid` derivation, `realm_access.roles` claim shape, `session_state` claim) live behind the interface. Migrating to Cognito means landing a second adapter, not rewriting the BFF.

This playbook walks through what changes and what doesn't, end-to-end.

---

## 1. What changes

### 1.1 Keycloak realm export

Realms in Keycloak are JSON-exportable, but Cognito does not import that format. The migration extracts the data we need:

- **Users** — username, email, attributes, federation links. Keycloak: `Realm settings → Action → Partial export → users`. Cognito: bulk-import via `cognito-idp create-user` (each user) OR `aws cognito-idp create-user-import-job` (CSV bulk).
- **Clients** — `helloworld-bff`, `openbao`, `grafana`, `wazuh-dashboard`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`. Each becomes a Cognito **app client** in the user pool.
- **Realm roles** — `platform_admin`, `tenant_user`, app-specific roles. Cognito: become **groups** in the user pool. Realm composite roles map to nested groups (Cognito has no native composites; expand at migration time).
- **Client scopes / mappers** — Cognito's "custom attributes" cover most needs; for token-shape mappers, Cognito uses Lambda triggers (`Pre Token Generation`).
- **Authentication flows** — Keycloak's flow customization → Cognito's `AdvancedSecurityMode` + Lambda hooks for any non-default behavior.

### 1.2 Token shape — what differs

| Keycloak claim | Cognito equivalent | Notes |
|---|---|---|
| `sub` | `sub` | Same; UUID. |
| `preferred_username` | `cognito:username` | Different claim name. Adapter normalizes. |
| `email` | `email` | Same. |
| `realm_access.roles` (nested) | `cognito:groups` (flat array) | Different shape. Adapter normalizes. |
| `session_state` | (not emitted) | `apps/lib/oidc.Claims.SessionState` will be empty for Cognito. Apps that branch on it (none today) need to be Cognito-aware. |
| `iss` | Cognito user-pool URL (`https://cognito-idp.<region>.amazonaws.com/<userPoolId>`) | URL shape; doesn't matter to apps. |
| `aud` | Cognito app-client ID | Same role; different value. |

The `apps/lib/oidc/Provider` interface already abstracts these. The Cognito adapter (`apps/lib/oidc/cognito.go`, NOT YET WRITTEN) implements the same interface and maps these to the vendor-neutral `Claims` struct.

### 1.3 `kid` derivation — Cognito uses RFC 7638

Cognito's JWKS publishes `kid` as the standard RFC 7638 thumbprint (the JWK-canonical-JSON SHA-256). Keycloak uses base64url(SHA-256(DER-PKIX)). Because the BFF asks the adapter for the right kid via `Provider.KidFor(pubDER)`, the BFF doesn't change — only the Cognito adapter computes a different kid for its own client_assertion JWS. The BFF carries on with private_key_jwt against Cognito unchanged.

**Caveat**: Cognito's app-client authentication may not accept private_key_jwt for all client types. The Cognito-supported client-auth methods are: client_secret_basic, client_secret_post (for confidential clients with secrets), and `client_secret` of `null` for public clients with PKCE. **Cognito does NOT natively support `private_key_jwt` for confidential clients**. The migration either:

- Uses client_secret_post (downgrades from public-key to shared-secret authentication; document the trade-off explicitly in the migration ADR), OR
- Wraps Cognito with a thin OIDC bridge that translates private_key_jwt to whatever Cognito wants. Heavy; only worth it if the threat model demands public-key client auth.

For initial Cognito migration, accept client_secret_post and rotate the client-secret on the same 90-day cadence as the realm-signing-key would have rotated. Document in the migration ADR.

### 1.4 Discovery URL

```
Keycloak:  https://auth.secforge.local/realms/<realm>/.well-known/openid-configuration
Cognito:   https://cognito-idp.<region>.amazonaws.com/<userPoolId>/.well-known/openid-configuration
```

This is the only env-var the BFF needs to change to point at Cognito: `BFF_KEYCLOAK_ISSUER` becomes the Cognito issuer URL. (The env var name keeps `KEYCLOAK_` for migration reasons; rename in a follow-up after migration is verified.)

### 1.5 BFF private_key_jwt → Cognito client_secret

If Cognito client_auth is `client_secret_post`:

- The BFF stops minting a JWS client_assertion (the `clientAssertion` function in `apps/helloworld-bff/oidc.go` becomes unused).
- The Cognito client_secret lives in OpenBao at `secret/data/cognito/clients/<bff-id>` (same path scheme as Keycloak today).
- The BFF's `Client.MintTokenForAudience` (Phase 6b-1) fetches the client_secret instead of computing private_key_jwt. The interface doesn't change; the implementation switches based on which OIDC adapter is active (Keycloak vs Cognito).

### 1.6 Sessions and refresh tokens

Cognito refresh tokens default to 30 days, configurable per-app-client. The BFF's session model ([ADR-0017](../02-decisions/0017-session-expiry-semantics.md)) caps idle at 30 min and hard-cap at 8 h, both shorter than Cognito's refresh token. The session refresh works the same way — call the Cognito token endpoint with `grant_type=refresh_token`.

DPoP: **Cognito does NOT natively support DPoP** as of mid-2026. The platform's DPoP-binding model (per [ADR-0011](../02-decisions/0011-bff-single-replica-local.md)) presupposes the IdP issues `cnf.jkt`-bound tokens. Migration options:

- **Drop DPoP** for the Cognito period: bearer tokens only. Trade off the proof-of-possession property; mitigate via short-lived tokens + DPoP-equivalent thumbprinting in `apps/lib/api-auth` middleware that the BFF mints (i.e., the BFF rebinds with its own DPoP layer between BFF and backend, even though Cognito doesn't).
- **Wait for Cognito DPoP support** — it's been on the AWS roadmap. If it lands before migration, this is moot.
- **Self-issue intermediary tokens** — the BFF uses Cognito for browser auth, then mints internal DPoP-bound tokens for its own use. Heavy; it's the same complexity as token-exchange ([ADR-0012 NO-GO](../02-decisions/0012-token-exchange-feasibility.md)).

### 1.7 What the BFF code does NOT change

This is the load-bearing claim of the vendor-neutral interface design:

- `apps/helloworld-bff/main.go` — unchanged.
- `apps/helloworld-bff/oidc.go` — the `clientAssertion` function may go unused but the rest of OAuth-flow plumbing (PAR, exchange, refresh, revoke) calls the same endpoints, just at Cognito URLs.
- `apps/helloworld-bff/proxy.go` — unchanged (uses `oidc.Claims` from the lib).
- `apps/helloworld-bff/openbao.go` (or whatever post-§A.5 secrets-loading path is) — unchanged. The `private_pem` field in OpenBao becomes a `client_secret` field, same KV path.

The `apps/lib/oidc.Provider` interface absorbs ALL the Cognito-specific quirks. That was the point of [F-APP-1, F-APP-2](../../Fix%20after%2007/00-audit-findings.md#f-app-1--high--keycloak-kid-derivation-hard-coded-in-bff) being scoped INTO Fix-after-07 §A.2 rather than left for migration time.

---

## 2. Migration steps (high-level)

This is the runbook layout, NOT the detailed steps (those land when migration actually runs):

1. **Realm export from Keycloak** — partial-export users + clients to JSON.
2. **Cognito user pool creation** — `aws cognito-idp create-user-pool` with the attribute schema mirroring Keycloak's.
3. **App-client creation** — one per Keycloak client.
4. **User import** — bulk via `create-user-import-job` from a CSV synthesized from the Keycloak export.
5. **Group creation + group-to-user mapping** — Cognito groups for each Keycloak realm role.
6. **`apps/lib/oidc/cognito.go`** — write the adapter.
7. **OpenBao re-keying** — flip the BFF's KV entry from `private_pem` → `client_secret` (or both, with the BFF reading whichever is present).
8. **Update `BFF_KEYCLOAK_ISSUER` env** to Cognito's issuer URL on every BFF Deployment.
9. **Update Keycloak client URL on every other consumer** (Grafana, Wazuh dashboard, OpenBao OIDC role) to Cognito's issuer URL.
10. **Verify** — login test for each of jason / alice / bob; each consumer's OIDC flow.
11. **Decommission Keycloak** — only after a soak period in which both run side-by-side.

---

## 3. Test plan

Confirm OIDC login, refresh, logout work end-to-end against Cognito BEFORE decommissioning Keycloak:

- [ ] Login flow: browser → BFF /login → Cognito hosted-UI → callback → session cookie set.
- [ ] Refresh: pre-expire access token; next API call triggers BFF's refresh path; new tokens come back; user does not see anything.
- [ ] Logout: BFF /logout → Cognito end-session → cookie cleared → next /login starts fresh auth.
- [ ] Group mapping: a user in Cognito group `platform_admin` gets `cognito:groups` claim with that value; `apps/lib/oidc.Claims.Roles` populated correctly; SpiceDB still authorizes.
- [ ] Keycloak rollback: Keycloak still up and reachable for at least one full session lifetime (8 h) so a fast rollback is possible.

---

## 4. What stays the same (this is the value of the refactor)

- BFF code (`apps/helloworld-bff/`) — unchanged except the `BFF_KEYCLOAK_ISSUER` env-var value.
- AuthZEN-facade — unchanged. Authorization is SpiceDB's job, not the IdP's.
- SpiceDB schema + relationships — unchanged. Roles are realm-agnostic; the adapter normalizes.
- OpenBao policies — same path schemes; the secret type changes (private_pem → client_secret).
- Backend APIs (Phase 9+) — they consume `apps/lib/api-auth/Middleware`, which talks to whichever adapter is wired in.
- Audit log shape — unchanged. The Q4 schema from [ADR-0012 § Resolution](../02-decisions/0012-token-exchange-feasibility.md#resolution-2026-05-01) carries `caller_user_sub` regardless of where `sub` came from.

---

## 5. Re-evaluation triggers

- Cognito gains DPoP support → re-evaluate, possibly skip the bearer-only intermediate stage.
- Cognito gains `private_key_jwt` for confidential app-clients → flip the auth method back to public-key.
- The threat model changes such that Cognito's group-explosion (no native composites) becomes operationally untenable → consider an alternative IdP (Okta, Auth0, PingFederate) and write a sister doc for that path.

---

## 6. What this doc does NOT promise

- It does NOT promise that Cognito's free tier covers the platform's user count. Verify pricing at migration time.
- It does NOT promise feature parity. Cognito does not support every Keycloak feature (e.g., advanced first-broker-login flows, custom SPIs). At migration time, audit which Keycloak features the platform actually uses and confirm Cognito covers each.
- It does NOT promise migration is one-step. Plan for a soak period running both side-by-side; have a rollback path.
