# Phase 3 — Identity Provider (Keycloak)

**Status:** ⬜ Not started · ⬜ In progress · ⬜ Complete

**Estimated time:** 3-5 days

**Prerequisites:** Phases 1 and 2 complete.

---

## Goal of this phase

Deploy Keycloak. Configure realms, set up passkey authentication, register skeleton clients for the BFFs, and verify a successful login flow over local HTTPS.

---

## What you (the human) need to do first

1. Confirm `secforge-keycloak-db` Postgres instance is reachable (Phase 1).
2. Confirm SPIRE is operational (Phase 2).
3. Have at least one hardware FIDO2 key on hand for passkey registration. (If keys haven't arrived yet, you can use a software passkey via Windows Hello or your phone for the first test, then re-register when the hardware key arrives.)
4. Decide which **external IdP** (if any) you want the `platform` realm to federate to for your team's authentication. Options: Google Workspace, GitHub, Microsoft, or none (Keycloak-local-only). For local edition, "none" is acceptable — you can be the sole admin and use Keycloak-local accounts with passkeys.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 3 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, docs/05-claude-code-prompts/phase-03-keycloak.md, and the IAM architecture overview in docs/01-architecture/00-overview.md before doing anything.

Your task is to deploy Keycloak, configure realms, set up passkey authentication, register skeleton clients, and verify the login flow.

## Phase 3.1 — Design

Document realm architecture in docs/01-architecture/01-iam-platform.md:

- Realm `platform`: For me and any team members. Local accounts (or federated to my external IdP if I provide one).
- Realm `secforge-tenants`: For SaaS tenants. Keycloak Organizations enabled.
- Per-enterprise realms: created on demand later.

Hostnames:
- `auth.secforge.local`: public OIDC/SAML endpoints
- `auth-admin.secforge.local`: admin console (NetworkPolicy restricting access; locally just your laptop, but build the muscle)

## Phase 3.2 — Deploy Keycloak

Use the Keycloak Operator. Deploy:
- Keycloak custom resource: 1 replica (HA isn't meaningful locally)
- Backed by `secforge-keycloak-db` Postgres
- TLS termination at ingress-nginx with cert from cert-manager (mkcert-issuer ClusterIssuer)
- securityContext: non-root, read-only root FS, drop ALL capabilities
- Resource limits: 1Gi memory, 1 CPU
- Pod has SPIFFE-CSI volume mounted, label `spiffe.io/spire-managed-identity: "true"`, identity = `spiffe://secforge.local/ns/keycloak/sa/keycloak`
- Liveness and readiness probes correctly configured
- The /health and /metrics endpoints exposed on the management port (not the public port)

## Phase 3.3 — Realm signing keys

Local edition uses Keycloak's default key provider (RSA keys generated in DB, encrypted with a master key). Document this as a deviation from the cloud edition (which uses AWS KMS PKCS#11) in docs/02-decisions/0003-keycloak-keys-local.md.

Configure each realm to use:
- Algorithm: RS256 or PS256 (NOT HS256)
- Key rotation: 90-day priority, with a 30-day overlap window for active and previous keys

## Phase 3.4 — Configure realms

### platform realm
- Default authentication flow: WebAuthn primary, password fallback for first-time setup only
- Required actions on first login: register WebAuthn credential
- Session timeouts: idle 15 min, absolute 8 hours, remember-me 30 days
- (Optional) Federated identity provider: my external IdP if I set one up

### secforge-tenants realm
- Self-service registration disabled (admin-mediated)
- Email verification required
- WebAuthn primary, password fallback (deprecate post-launch — set a calendar reminder)
- TOTP available as recovery factor only
- Session timeouts: idle 30 min, absolute 12 hours
- Organizations feature enabled
- Identity provider federation: configurable per organization (SAML and OIDC)

For each realm:
- Configure event listeners: log all login/logout events to STDOUT as JSON (will route to Wazuh in Phase 7)
- Set security headers via realm settings: HSTS, X-Frame-Options, etc.
- Disable: Implicit flow, ROPC, OAuth 2.0 (we use 2.1 baseline)
- Enable: PKCE required for all clients, PAR, DPoP, refresh token rotation with reuse detection set to "all" scope

## Phase 3.5 — Register skeleton clients

We don't have apps yet but register placeholder clients for each future BFF:

In `secforge-tenants` realm:
- `helloworld-bff`: confidential, redirect URIs `https://app.secforge.local/auth/callback`, post-logout `https://app.secforge.local`, requires PAR + DPoP, uses private_key_jwt for client auth
- `proposal-forge-bff`: similar, redirect to `https://pf.secforge.local/...`
- `project-tracker-bff`: similar, redirect to `https://pt.secforge.local/...`
- `pm-bff`: similar, redirect to `https://pm.secforge.local/...`

For each client, generate a client signing keypair. Store in a Kubernetes Secret in the `app` namespace; we'll migrate to OpenBao in Phase 5.

## Phase 3.6 — Admin console isolation

Configure two Ingress resources for Keycloak:
1. `auth.secforge.local` — public OIDC/SAML endpoints
2. `auth-admin.secforge.local` — admin console only

For the admin Ingress, add NetworkPolicy restricting source CIDR. Locally, this is your laptop's IP; for cloud later, this would be a bastion or VPN range.

## Phase 3.7 — Test the login flow

Manually:
1. Visit https://auth.secforge.local/realms/platform/account
2. Sign in (use the bootstrap admin account first time)
3. Register a passkey using your hardware FIDO2 key
4. Sign out, sign back in — verify passkey works (no password prompt)

Then automated test:
- Use a small Go program or curl with the OIDC discovery doc to perform the auth code flow programmatically (against a service account in a test realm with TOTP for automation)
- Verify access token is signed with the configured RS256/PS256 key
- Verify refresh token rotation works (request 2x with same refresh, second should fail)
- Verify token introspection works
- Verify DPoP-bound tokens contain the `cnf.jkt` claim

## Phase 3.8 — Documentation

Update:
- docs/01-architecture/01-iam-platform.md
- docs/03-runbooks/keycloak-operations.md (add realm, rotate keys, recover admin, restore from backup)
- docs/03-runbooks/realm-signing-key-rotation.md
- docs/02-decisions/0003-keycloak-keys-local.md (the file-key vs cloud-KMS gap)

## Constraints

- Realm signing keys use RS256 or PS256 (file-stored is the local gap; documented)
- Admin console MUST NOT be on the same hostname as public OIDC endpoints
- WebAuthn is the primary authenticator
- No client uses HS256 for tokens
- Refresh token rotation with reuse detection enabled on every client
- All events stream to STDOUT as JSON
- Keycloak admin password is bootstrap-only; primary auth thereafter is passkey
```

---

## Success criteria

- [ ] Keycloak Operator-managed deployment, Ready
- [ ] Postgres backend connected, encrypted in transit
- [ ] Both realms (platform, tenants) configured per spec
- [ ] Four skeleton BFF clients registered
- [ ] Admin console on separate hostname with NetworkPolicy
- [ ] You can log in with a passkey from your browser at `https://auth.secforge.local`
- [ ] Refresh token rotation with reuse detection verified
- [ ] Documentation and ADRs updated
- [ ] PLAN.md updated

---

## Troubleshooting

### "Keycloak operator can't reach Postgres"
NetworkPolicy or service issue. `kubectl exec -n keycloak deploy/keycloak -- nc -vz <postgres-host> 5432`. Also check the Postgres connection string includes `?sslmode=require` if Postgres is configured for TLS.

### "WebAuthn registration fails — RP ID mismatch"
The Relying Party ID must be `secforge.local` (the parent), not `auth.secforge.local`. Configure in the realm's WebAuthn policy. Otherwise, passkeys registered for one subdomain won't work on others.

### "Browser says cert is invalid"
mkcert CA isn't in your Windows trust store. See `docs/00-getting-started/03-local-dns-and-tls.md`.

### "Login loop after federated login"
If using external IdP federation, verify redirect URIs match exactly. Also check user attribute mapping (email is required).

---

## What's next

[Phase 4 — Authorization (SpiceDB)](./phase-04-spicedb.md).
