# IAM Platform (Keycloak)

> **Production note.** Written for the local edition; the security architecture below is unchanged in production, but the substrate differs. In prod: ingress is the **Istio gateway** (not ingress-nginx); TLS is **Let's Encrypt** (not mkcert); DNS is real **`*.secforge.dev`** (not a hosts file); the cluster is **Hetzner k3s** (not Docker Desktop); the Keycloak admin console is **`kc.secforge.dev` (tailnet-only)** (not `auth-admin.secforge.dev`); the SPIRE trust domain is **`secforge.platform`**; auth factor is **passkeys** ([ADR-0036](../02-decisions/0036-production-authentication-factors-passkeys.md)). See [PLAN.md](../../PLAN.md) and [00-overview.md](./00-overview.md).

> Companion ADRs:
> - [ADR-0006 — Keycloak realm signing keys (local edition)](../02-decisions/0006-keycloak-keys-local.md)
> - [ADR-0007 — TOTP instead of passkeys for local development](../02-decisions/0007-totp-instead-of-passkeys-locally.md) (supersedes [ADR-0002](../02-decisions/0002-local-passkey-via-windows-hello.md) for the local-dev window)
> - [ADR-0001 — Local-first build](../02-decisions/0001-local-first.md)
>
> Companion docs:
> - [01a-realm-to-app-matrix.md](./01a-realm-to-app-matrix.md) — operational reference for "which realm does my new app go in," the live client-per-realm distribution, audience-mapper cheat sheet, and the checklist for adding a new app
>
> Runbooks: [keycloak-operations.md](../03-runbooks/keycloak-operations.md), [realm-signing-key-rotation.md](../03-runbooks/realm-signing-key-rotation.md).

This document describes the Keycloak deployment, realm architecture, authentication factors, client model, and admin-console isolation for the SecForge platform's local edition. The architecture is identical to the cloud edition; only the substrate beneath it changes.

---

## Goals

1. **A single identity provider** issuing OIDC tokens to every BFF and admin console in the platform.
2. **Strong, phishing-aware authentication** by default — TOTP today (interim), passkeys before any non-local exposure.
3. **Multi-tenant by realm structure** — platform staff, SaaS tenants, and per-enterprise dedicated realms have separate authentication boundaries.
4. **Admin console isolation** — the Keycloak admin UI is on a different hostname from public OIDC endpoints, with NetworkPolicy gating source IPs. Build the muscle memory locally; same pattern in cloud.
5. **Same configuration shape locally and in cloud** — what changes at migration is the realm signing-key custody (DB → cloud KMS PKCS#11) and the federation surface (none → external IdPs). Realm definitions, client definitions, flows, and policies move unchanged.

---

## Realm architecture

| Realm | Purpose | Auth model | Federation |
|---|---|---|---|
| `master` | Keycloak's own admin realm — bootstrap admin only | local | none |
| `platform` | Project owner + future team members | TOTP + recovery codes (interim, see ADR-0007); revert to passkeys at production hardening | optional external IdP at owner's choice; currently **none** |
| `secforge-tenants` | SaaS-tier customers (multi-tenant via Keycloak Organizations) | TOTP + recovery codes (interim); SAML/OIDC federation per organization | configurable per organization |
| `enterprise-{name}` | Dedicated realms for enterprise customers, created on demand | per-enterprise; defaults match `secforge-tenants` | per enterprise IdP |

Per-enterprise realms are not provisioned in this phase — only the `platform` and `secforge-tenants` realms are configured during Phase 3.

### Why three+ realms (not one)

Realms are Keycloak's authentication boundary. Cross-realm token leakage requires a bug; cross-tenant token leakage within a realm is a configuration error away. Separating staff, SaaS tenants, and enterprises into different realms means:

- A misconfigured client in `secforge-tenants` cannot accidentally grant access to a `platform` admin operation.
- Per-enterprise identity providers, password policies, MFA policies, and session lifetimes are independently configurable.
- Compromise of a tenant's external IdP cannot mint tokens for the platform realm.

The cost is operational: more realms means more places to check for a misconfiguration. We accept that cost; the alternative (one big realm with role-based separation) collapses the boundary into application code.

---

## Hostnames

| Hostname | Purpose | Network policy |
|---|---|---|
| `auth.secforge.dev` | Public OIDC/OAuth/SAML endpoints (`/realms/{realm}/...`, JWKS, token, authorize, introspect, revoke) | open within the cluster + ingress |
| `auth-admin.secforge.dev` | Keycloak admin console (`/admin/...`) | NetworkPolicy restricting source — locally, just the developer machine |

**Why split hostnames.** Putting the admin console on the same hostname as the public OIDC endpoints forfeits the most useful network-layer control we have: "the admin UI should never be reachable from the open internet." Even when the admin UI requires authentication, exposing it on a public hostname grows the attack surface unnecessarily (CSRF tokens, version-fingerprinting, brute force on bootstrap accounts during migrations). We split locally so the muscle memory carries to cloud, where the admin host sits behind a bastion or VPN.

This is a bright-line rule from CLAUDE.md: *"Putting Keycloak's admin console on the same hostname/path as the public OIDC endpoints"* is a "things that should NEVER happen."

---

## Authentication factors

> **Important.** The factor list below is the *interim* local-development model captured in [ADR-0007](../02-decisions/0007-totp-instead-of-passkeys-locally.md). The architecture commitment is passkeys + hardware FIDO2 keys. Do not deploy this realm configuration past loopback / LAN without first running the revert-to-passkeys playbook.

### Primary factor: TOTP (RFC 6238, software authenticator app)

Required for all users in both `platform` and `secforge-tenants` realms. Enrollment is mandatory at first login (`CONFIGURE_TOTP` required action).

Configured per realm:

- Algorithm: SHA-1 (RFC 6238 default; broadest authenticator-app compatibility)
- Digits: 6
- Period: 30 seconds
- Look-ahead window: 1 (one period either side, to absorb clock skew)

### Recovery factor: recovery authentication codes

Keycloak's `recovery-codes` feature (preview-graduated GA in Keycloak 26.x) is enabled at the server level. Enrollment is mandatory immediately after TOTP enrollment (`CONFIGURE_RECOVERY_AUTHN_CODES` required action).

- 10 single-use codes generated at enrollment.
- **Displayed to the user once.** No second display, no recovery via the admin UI — admin must regenerate (which invalidates the previous set).
- Used as a single-step alternative to TOTP when the user has lost their authenticator app.

**Operational expectation, communicated to every user at enrollment:** store the 10 codes in a password manager (1Password, Bitwarden, KeePassXC) before continuing. Without them, "I lost my phone" means "the admin destroys your account and re-enrolls you" — which is acceptable for the project owner but not for tenant users.

### Forbidden factors (per CLAUDE.md and policy)

- **SMS / phone-based OTP** — phishable, SIM-swappable, and explicitly forbidden by CLAUDE.md.
- **Static passwords as the primary factor.** Passwords exist *only* as a bootstrap mechanism for the realm administrator (set on the master realm by the Keycloak Operator, used once to create the first user, then deprecated).
- **Email-link login** — phishable; not enabled.

### Bootstrap admin (post-Phase-3.7 state)

The Keycloak Operator's `bootstrapAdmin` field was used once to seed the master-realm admin during Phase 3.2; the resulting `keycloak-bootstrap-admin` Secret + master-realm `bootstrap-admin` user were both deleted at the end of Phase 3.7 once the project owner's TOTP-enrolled `jaupole` (master realm) and `jason.upole` (platform realm) users were verified.

The Keycloak Operator continues to manage a `keycloak-initial-admin` Secret (auto-recreated on every reconcile when no custom `bootstrapAdmin` is in the CR). Its credentials are functionally inert — Keycloak's bootstrap-admin creation logic only runs if the master realm has zero admin users, which it doesn't. The Secret exists only so the StatefulSet's `KC_BOOTSTRAP_ADMIN_*` env refs (`Optional: false`) resolve. Don't fight the operator on this; it's documented in the operations runbook.

### Factor model at a glance

| Factor | `platform` | `secforge-tenants` | Allowed? |
|---|---|---|---|
| TOTP (authenticator app) | primary | primary | yes (interim) |
| Recovery codes (10 single-use) | recovery-only | recovery-only | yes |
| Passkey / WebAuthn | not configured (revert before prod) | not configured | architectural target — re-enable at production hardening |
| Hardware FIDO2 (cross-platform) | not configured | not configured | architectural target |
| Password (interactive) | bootstrap admin only | disabled | bootstrap only |
| SMS / push / email-link | n/a | n/a | **never** |

---

## Session and token model

Identical for both realms unless noted.

### Sessions

| Property | `platform` | `secforge-tenants` |
|---|---|---|
| SSO Session Idle Timeout | 30 min | 30 min |
| SSO Session Max | 8 hours | 12 hours |
| Remember-Me | 30 days (idle 7 days) | disabled |
| Offline session idle | disabled (no offline tokens) | disabled |

`platform` keeps a tighter absolute max (8 h vs 12 h) because admin sessions hold authority over realm configuration. The SSO idle was tightened to 15 min historically but raised to 30 min on 2026-06-13 to match the tenant realm: the BFF (`@jaupole/ecosystem-auth`) refreshes the IdP token lazily — only on access-token expiry, and Keycloak's SSO idle clock resets only on a refresh — so a 15-min idle could lapse during an active-but-quiet stretch while the BFF's own 30-min idle was still sliding, signing an active staff user out. The BFF idle remains the effective idle policy.

### OAuth / OIDC posture

Same for both realms:

- **OAuth 2.1 baseline only.** Disabled flows: Implicit, ROPC (password grant), OAuth 2.0 hybrid. (Keycloak's "Standard Flow" = Authorization Code + PKCE remains enabled.)
- **PKCE required** on every confidential and public client.
- **Pushed Authorization Requests (PAR) required** for every client.
- **DPoP required** for every confidential client. Tokens carry `cnf.jkt` (JWK thumbprint of the DPoP key) and the resource server validates the binding on every request.
- **Refresh-token rotation with reuse detection** — set to "all" scope: any reuse of a previously-rotated refresh token revokes the entire grant family.
- **Access-token signing** — RS256 or PS256. **Never HS256** (HS256 implies a shared secret with the resource server; we don't share secrets between Keycloak and BFFs, and HS256 in JWT libs is the source of "alg=none" / "alg confusion" bugs).
- **Access-token TTL**: 5 minutes. Refresh tokens carry their own short lifetime tied to session-idle.

### Realm signing keys

- Algorithm: RS256 (default) and PS256 (available for clients that prefer it).
- Storage: Keycloak default key provider — keys live in the realm DB, encrypted by Keycloak's master encryption key. **This is the local-vs-cloud delta**: cloud edition uses AWS KMS via PKCS#11. Captured in [ADR-0006](../02-decisions/0006-keycloak-keys-local.md).
- Rotation: 90-day priority rotation with a 30-day overlap window (active + previous keys both publish in JWKS). Procedure: [realm-signing-key-rotation.md](../03-runbooks/realm-signing-key-rotation.md).

---

## Skeleton client model (Phase 3.5)

Four BFF clients are pre-registered in `secforge-tenants` for the apps coming in Phases 9–10. None of the apps exist yet; the registrations are placeholders so we don't have to round-trip through Keycloak admin every time we wire up a new BFF.

| Client ID | App | Public URL | Redirect URI |
|---|---|---|---|
| `helloworld-bff` | Phase 9 demo app | `https://app.secforge.dev` | `https://app.secforge.dev/auth/callback` |
| `proposal-forge-bff` | Proposal Forge | `https://pf.secforge.dev` | `https://pf.secforge.dev/auth/callback` |
| `project-tracker-bff` | Project Tracker | `https://pt.secforge.dev` | `https://pt.secforge.dev/auth/callback` |
| `pm-bff` | Future PM app | `https://pm.secforge.dev` | `https://pm.secforge.dev/auth/callback` |

For each client:

- **Confidential** — server-side BFF holds the credential.
- **Client authentication: `private_key_jwt`** — the BFF presents a signed JWT (RS256) instead of a static client secret. The BFF holds the private key; Keycloak holds the JWK.
- **PAR required, PKCE required, DPoP required.**
- **Refresh-token rotation with reuse-detection enabled.**
- **Post-logout URI** matches the app origin (no callback path).

Per-client signing keys are generated during Phase 3.5 and stored in the `app` namespace as Kubernetes Secrets (key name `private.pem`). This is interim — Phase 5 (OpenBao) migrates these into OpenBao's PKI / KV stores so the BFF fetches them at startup with a SPIFFE-bound role instead of mounting a static Secret.

---

## Event streaming

Every realm has the **JSON event listener** enabled. All authentication, login, logout, token, admin, and identity-provider events stream to Keycloak's STDOUT in JSON form. STDOUT is collected by the cluster's logging stack (Loki/Promtail in Phase 7; Wazuh ingests the same stream).

Event types streamed:

- `LOGIN`, `LOGIN_ERROR`, `LOGOUT`, `LOGOUT_ERROR`
- `CODE_TO_TOKEN`, `CODE_TO_TOKEN_ERROR`
- `REFRESH_TOKEN`, `REFRESH_TOKEN_ERROR`
- `INTROSPECT_TOKEN`, `INTROSPECT_TOKEN_ERROR`
- `REGISTER`, `UPDATE_PASSWORD` (legacy), `UPDATE_TOTP`, `REMOVE_TOTP`
- `RESET_PASSWORD`, `SEND_RESET_PASSWORD`
- All admin-realm events (realm config changes, client changes, user changes, role changes)

Event TTL in DB: 7 days (the durable copy is in Loki/Wazuh; the DB copy is for the admin UI's "Events" view).

---

## Network and TLS posture

- **Ingress**: ingress-nginx terminates TLS for both hostnames. Certs are issued by cert-manager from the mkcert local CA (the `mkcert-issuer` `ClusterIssuer` from Phase 1).
- **In-cluster TLS to Keycloak**: ingress-nginx → Keycloak Service is HTTP within the namespace. Locally acceptable; cloud will add Istio Ambient mTLS (Phase 6) so the in-cluster hop is encrypted.
- **Postgres connection**: Keycloak → `secforge-keycloak-db` uses TLS (`sslmode=require`; encrypts in transit, no certificate verification). Tightening to `sslmode=verify-full` requires mounting the CA cert as `sslrootcert` in the JDBC URL — tracked as a follow-up at production-hardening time. The CA is already loaded into Keycloak's Java truststore via `spec.truststores.pg-ca`.
- **Postgres ingress NetworkPolicy**: `default-deny-ingress` (selector `{}`) applies to the Postgres pod too because it's in the same namespace. An explicit `allow-postgres-ingress` policy permits 5432 from Keycloak pods, realm-import job pods, same-cluster replicas, and the `postgres-operator` namespace. Without this allow-rule, Keycloak's first cold-start after the NetworkPolicies are applied fails with `Failed to obtain JDBC connection` because TCP/5432 is blocked at the destination pod.
- **Workload identity**: Keycloak pod gets a SPIFFE ID `spiffe://secforge.platform/ns/keycloak/sa/keycloak` via the SPIFFE-CSI volume. It doesn't *use* the SVID for anything yet (Postgres auth is still password-based at this stage); the volume is mounted now so the SPIFFE library is in place when Phase 5 introduces JWT-SVID-bound credentials.

### Pod security

- `runAsNonRoot: true`, `runAsUser: 1000`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`
- `readOnlyRootFilesystem`: **`true` on the operator container, `false` on the Keycloak container** (see gap below). The keycloak namespace enforces Pod Security Standards `restricted`, which does not require RO root; the loosening is local to the keycloak workload.

**Known local gap — Keycloak container has a writable root FS.** Keycloak's `--features=recovery-codes` build-time flag forces the operator to set `startOptimized: false`, which causes Quarkus to re-augment the Keycloak JAR (`/opt/keycloak/lib/quarkus/...`) on every pod start. That requires the root filesystem to be writable. PSS `restricted` and the rest of the container hardening (drop ALL caps, no privesc, non-root UID, seccomp RuntimeDefault) remain in force.

The proper fix is to build a custom Keycloak image with `kc.sh build --features=recovery-codes` baked in, then set `spec.startOptimized: true` in the Keycloak CR and re-enable `readOnlyRootFilesystem: true`. We defer that work to the production-hardening pass — same trigger as ADR-0007 (revert-to-passkeys).

### Resource budget

| Resource | Request | Limit |
|---|---|---|
| Memory | 512 Mi | 1 Gi |
| CPU | 200 m | 1 |

The 1 Gi limit accounts for Keycloak's JVM + caches under modest load. Single replica locally; cloud edition runs 2+ replicas behind a service.

### Probes

- **Liveness**: `GET /health/live` on the management port (9000)
- **Readiness**: `GET /health/ready` on the management port (9000)
- **Startup**: `GET /health/started` on the management port (9000), 60 failures × 5s = ~5 minute startup budget for first-time DB schema creation

The management port is **not** exposed via the public Ingress. Health and metrics are scrape targets for Prometheus (Phase 7) inside the cluster only.

---

## What changes at cloud migration

Keep this list short and explicit so the migration playbook can reference it:

1. **Realm signing keys**: file/DB-backed → AWS KMS (or GCP / Azure equivalent) via PKCS#11. The Keycloak `kc.sh` flag is `--features=pkcs11-keys` and a config block per realm. Procedure in the migration playbook; key material does not move — we generate fresh keys in KMS and overlap-rotate.
2. **Auth factor**: TOTP-primary → passkey-primary + hardware-FIDO2 for admin (revert ADR-0007 to ADR-0002 model; subsequently tighten to mandatory hardware FIDO2 for the `platform` realm).
3. **Admin console source restriction**: NetworkPolicy → bastion / VPN CIDR.
4. **Postgres**: in-cluster CloudNativePG → managed Postgres (RDS / Cloud SQL).
5. **Logs**: STDOUT → Loki + Wazuh stays the same; only the destinations and retention change.
6. **Replicas**: 1 → 2+ behind Service, with sticky session disabled (Keycloak is stateless once tokens are issued).

Application-side configuration (BFF redirect URIs, client IDs, scopes) does not change between local and cloud. Hostnames change; everything else stays.

---

## What is *not* in this phase

For the avoidance of confusion:

- **Keycloak Organizations setup** — the feature is *enabled* on `secforge-tenants` but no organizations are created. Real tenant onboarding happens with the apps in Phase 10.
- **Federated identity providers** — not configured for `platform` (project owner declined external IdP) or `secforge-tenants` (configured per organization at onboarding time).
- **User provisioning APIs** (SCIM) — not in scope for Phase 3.
- **Step-up authentication** — defined as future work; the architecture supports it (Authentication Flow conditions on requested ACR), and Phase 9/10 wire it into the BFF.
- **Per-enterprise dedicated realms** — created on demand later.
