# Realm-to-App Matrix

> **Use this doc when adding a new ecosystem app**, a new BFF, or any new
> client registration in Keycloak. It answers: which realm, which clientId
> convention, which audiences, which protocol mappers.
>
> Companion doc: [01-iam-platform.md](./01-iam-platform.md) (overall
> Keycloak architecture). Companion plan: Shape B realm split decision at
> `~/.claude/plans/so-for-the-current-polymorphic-thompson.md`.

---

## The Three-Tier Realm Model

| Realm | Who Lives Here | Created |
|---|---|---|
| `master` | Sole Keycloak bootstrap admin (`jaupole`, WebAuthn-required, no password) | Auto-created by Keycloak |
| `platform` | Staff / operators / platform-component clients (OpenBao UI, Grafana, Wazuh dashboard) | `platform-realm.yaml` |
| `secforge-tenants` | All SaaS customer organizations + their end-users (Keycloak Organizations enabled) | `secforge-tenants-realm.yaml` |
| `enterprise-{name}` | Per-customer dedicated realm for enterprise contracts demanding their own IdP federation / signing keys | On-demand, future |

Cross-references:
- [ADR-0008 in 01-iam-platform.md §"Realm architecture"](./01-iam-platform.md#realm-architecture) — three-tier rationale
- [ADR-0018](../02-decisions/0018-multi-tenancy-rls-strategy.md) — two-layer (RLS + SpiceDB) tenant isolation inside `secforge-tenants`
- [ADR-0026](../02-decisions/0026-org-defined-custom-roles-rbac-layer.md) — org-defined custom role bundles in `control_db`

---

## Decision Tree — Which Realm Does My New App Go In?

```
Is this an operator-only tool (you log in, no customers)?
├─ YES → platform realm.
│         Examples: OpenBao UI, Grafana, Wazuh dashboard, Admin Console (planned).
│
└─ NO → Does it serve customer end-users?
        ├─ YES, AND it's a multi-tenant SaaS surface (every paying org gets the same surface)
        │       → secforge-tenants realm.
        │         Examples: Portal (tenant face), Member Hub, future Proposal Forge tenant UI,
        │         future Project Tracker tenant UI.
        │
        ├─ YES, AND it's for ONE specific enterprise customer that bought a dedicated environment
        │       → enterprise-{customer} realm (create on demand; not deployed today).
        │
        └─ It's a backend API that needs to validate tokens from BOTH staff + tenant callers
                → Trust BOTH issuers (platform AND secforge-tenants). The clientId still
                  registers in both realms; SpiceDB does the per-request authorization.
                  Examples: Control backend.
```

---

## Live Client Distribution (As Of 2026-05-23)

### `platform` Realm

Operators + platform-component tools. **No tenant traffic.**

| ClientId | Type | Purpose | App / Consumer |
|---|---|---|---|
| `openbao` | confidential (OIDC) | Operator login to OpenBao UI / `bao login -method=oidc` | OpenBao |
| `grafana` | confidential (OIDC) | Operator login to Grafana UI | Grafana |
| `wazuh-dashboard` | confidential (OIDC) | Operator login to OpenSearch Dashboards | Wazuh |
| `control` | confidential (OIDC, server-side) | Staff side of Ecosystem Control backend — audience target for staff tokens | Control backend |
| `control-admin` | confidential (service-account) | Control → Keycloak Admin API for **staff-user** management | Control backend |
| `control-portal` | public (PKCE) | Staff face of Portal (future Admin Console will live here) | Portal SPA (current) / Admin Console (planned) |
| `member-hub` | confidential (OIDC + PKCE) | Vestigial — staff-side Member Hub login (operator's own account) | Member Hub backend |
| `member-hub-admin` | confidential (service-account) | Vestigial — Member Hub → Keycloak Admin API for staff users | Member Hub backend |
| `member-hub-system` | confidential (service-account) | Vestigial — Member Hub → Control system client | Member Hub backend |

The three `member-hub*` clients are listed as "vestigial" because in Shape B the Member Hub user-flow is tenant-realm. They remain in `platform` for the operator's testing account and any future operator-facing Member Hub views; they can be deleted after the cutover settles.

### `secforge-tenants` Realm

SaaS customer organizations + their end-users. **No operator traffic.**

| ClientId | Type | Purpose |
|---|---|---|
| `control` | confidential (OIDC, server-side) | Tenant side of Control backend — audience target for tenant tokens |
| `control-admin` | confidential (service-account) | Control → Keycloak Admin API for **tenant-user** management + Keycloak Organizations provisioning (`manage-organizations`) |
| `control-portal` | public (PKCE) | Tenant face of Portal — tenant admins manage their org here |
| `member-hub` | confidential (OIDC + PKCE) | Tenant users log into Member Hub |
| `member-hub-admin` | confidential (service-account) | Member Hub → Keycloak Admin API for tenant-user management |
| `member-hub-system` | confidential (service-account) | Member Hub → Control system client for backend-to-backend |

**ClientId naming convention:** the SAME `clientId` exists in both realms (e.g. `member-hub`). The realm is the discriminator. App backends decide trust by the `(issuer, clientId)` tuple. The `OIDC_CLIENT_ID` env var stays realm-agnostic in app code; `OIDC_ISSUER` (or `OIDC_REALM`) carries the realm-specific part.

---

## Audience Mappers — Cheat Sheet

Every confidential client should carry an `oidc-audience-mapper` adding its own clientId to `aud`. Without this, strict `aud` checks 401 every token. This applies to **both realms equally** — every client in both realms needs the self-audience mapper.

Cross-audience mappers (when client A's tokens need to be valid at client B):

| Source ClientId | Target Audience | Why |
|---|---|---|
| `control-portal` (both realms) | `control` | Portal calls Control's API with the same session token |
| `member-hub` (both realms) | `control` | Member Hub calls Control's `/api/v1/me` for active-org context |

Adding a new tenant-facing app's client? At minimum:
1. Self-audience mapper (`<your-clientId>`)
2. Cross-audience to `control` if your app needs to call Control's API

---

## Backend Trust Anchors — What Each Service Validates

| Service | Trusted Issuers | Rejects If… |
|---|---|---|
| `control` backend | `https://auth.secforge.dev/realms/platform` AND `https://auth.secforge.dev/realms/secforge-tenants` | Issuer not in list, or `aud` doesn't include `control`, or signature fails JWKS check |
| `member-hub` backend | `https://auth.secforge.dev/realms/secforge-tenants` (and `platform` only for the vestigial operator testing path) | Same shape; primary realm is `secforge-tenants` |
| `openbao`, `grafana`, `wazuh-dashboard` | `https://auth.secforge.dev/realms/platform` only | Tenant tokens are explicitly NOT accepted at operator tools |
| `portal` SPA (no backend) | Issuer matches its configured realm (depends on which shell: tenant Portal validates `secforge-tenants`; staff Admin Console validates `platform`) | Token from the other realm — the SPA never sees it |

Per-realm JWKS endpoints (each realm has its own signing keys):
- `https://auth.secforge.dev/realms/platform/protocol/openid-connect/certs`
- `https://auth.secforge.dev/realms/secforge-tenants/protocol/openid-connect/certs`

A token issued by one realm CANNOT be validated against the other realm's JWKS — this is the cryptographic boundary that makes the realm split a real security control, not just a label.

---

## Adding A New App — Checklist

When you add a new ecosystem app, work through this list:

1. **Decide the realm(s)** using the decision tree above. Tenant-facing → `secforge-tenants`. Operator-only → `platform`. Backend that serves both → register in both, validate both issuers.
2. **Pick a `clientId`** that's short, lower-case, hyphenated, matches the app's slug (e.g. `proposal-forge`, `project-tracker`). Same clientId in both realms if dual-registered.
3. **Add the client(s)** to the relevant realm-import YAML file(s):
   - `platform/manifests/keycloak/realms/platform-realm.yaml` if platform-realm needed
   - `platform/manifests/keycloak/realms/secforge-tenants-realm.yaml` if tenant-realm needed
4. **Add the self-audience mapper** to each client (mandatory — see project memory `project_keycloak_audience_mappers.md`).
5. **Add any cross-audience mappers** (typically `control` if your app calls Control's API).
6. **Add service-account `USER_ENTITY` rows** if the client has `serviceAccountsEnabled: true`. For tenant-realm service accounts that manage Keycloak Organizations, include `manage-organizations` / `view-organizations` clientRoles.
7. **Update the live cluster** if applying without a full realm rebuild: use the rotation/codification pattern from `project_keycloak_client_secret_rotation_pattern` to publish the operator-generated client secret to OpenBao kv / consumer Secrets.
8. **Update this matrix** with your new client row(s) so the next person can grep for the live state of the world.
9. **Update the API security tracker** (`docs/06-reference/api-security-status.md`) per `reference_api_security_tracker`.

---

## What's NOT In This Matrix

- **Per-organization identity providers** (Keycloak Organizations IdP federation) — those are created at tenant-org-onboarding time by the Portal signup wizard, not by adding to a realm-import YAML. Tracked in the Portal app's docs.
- **Enterprise-realm clients** — created on demand. When the first enterprise customer is onboarded, a new `enterprise-{customer}-realm.yaml` will be added under `platform/manifests/keycloak/realms/` and this matrix will gain a section for it.
- **Per-app role surface visibility** — that's tenant-defined config in `control_db.org_roles`, not Keycloak metadata. See [ADR-0026](../02-decisions/0026-org-defined-custom-roles-rbac-layer.md).
