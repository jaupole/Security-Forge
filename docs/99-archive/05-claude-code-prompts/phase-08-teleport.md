> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Phase 8 — Privileged Access (Teleport) — Optional Locally

> **Navigation:** ⬅ [Previous: Phase 7d — Rotation + housekeeping](./phase-07d-rotation-housekeeping.md) · [Next: Phase 9 — Hello World](./phase-09-hello-world.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phase 7 ✅ (typically run after 7d, but not strictly required)
> **Blocks:** (none structurally — Phase 8 is **optional locally**; skip with an ADR if you'll never SSH or expose internal admin UIs)
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ⬜ Not started · ⬜ **Skipped (with ADR)** option available — document in `docs/02-decisions/0006-skip-teleport-locally.md` if you choose to skip.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 2 days

**Prerequisites:** Phases 1-7 complete.

---

## Should you do this phase locally?

**Strong arguments to do it locally:**
- You build the muscle memory for production-realistic admin access
- You can test the OIDC federation, hardware FIDO2 enforcement, and session recording flows now (cheap) instead of later (under pressure)
- It exercises the SPIRE → OpenBao → Postgres dynamic-creds chain end-to-end
- ~2 GB additional RAM is fine on your 32 GB machine

**Arguments to skip locally:**
- Direct kubectl from Docker Desktop is more convenient day-to-day
- Wazuh / Grafana / OpenBao UIs are already locally restricted (NetworkPolicy)
- You're not yet exposing anything publicly, so the "no SSH, only Teleport" hardening doesn't bite yet

**Recommendation**: Do it. The pattern is what you want to be production-realistic about, and getting it working under the no-stress local conditions is much better than fighting it during a launch crunch.

If you really want to skip: write `docs/02-decisions/0006-skip-teleport-locally.md` documenting the decision and the gap (no centralized session recording, no cert-based access for kubectl, etc.). Then jump to Phase 9.

---

## Goal of this phase

Deploy Teleport Community Edition. Federate to Keycloak. Enforce hardware FIDO2 for the admin role. Register the local cluster as a Kubernetes target. Verify session recording.

---

## What you (the human) need to do first

1. Confirm hardware FIDO2 keys are on hand (registered in Keycloak in Phase 3 — or, per the local-dev window in ADR-0007, confirm TOTP is enrolled in your Keycloak account).
2. Decide cluster name. Suggested: `secforge-local`.

---

## Keycloak clients required (verify or create BEFORE starting)

OIDC integration in this phase requires a new Keycloak client. **Confirm it exists before running the Claude Code prompt.**

| Client ID | Realm | Confidential | Redirect URIs | Created by |
|---|---|---|---|---|
| `teleport` | `platform` | yes (client-secret) | `https://tp.secforge.local:3080/v1/webapi/oidc/callback`, plus any extra Teleport callback URIs the chart docs specify | This phase. Provision via `infrastructure/keycloak/clients/teleport.sh` (write the script using `infrastructure/keycloak/clients/openbao.sh` as a template), or create via the admin UI. |

The client's Default scopes must include **`roles`** (Keycloak's built-in scope). The realm-roles mapper on the `roles` scope must emit `realm_access.roles` to ID token + access token + userinfo.

**Realm role to define:** `teleport_admin` (assignable to humans who should get Teleport's `editor` role) and `teleport_member` (assignable to humans who get Teleport's `access` role).

Lesson from Phase 5: use the kcadm script to provision the client idempotently — don't rely on inline kcadm calls in the Claude Code prompt, since admin auth (jaupole + master password + fresh TOTP) is fragile and reproducing the client by clicking through the admin UI on every fresh-cluster bootstrap is tedious.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 8 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-08-teleport.md before doing anything.

Your task is to deploy Teleport Community Edition locally and configure it as the access path for human admins.

## Phase 8.1 — Design

Document in docs/01-architecture/09-privileged-access.md:
- Teleport Community Edition (open source, Apache 2.0)
- Single replica auth + proxy (HA in cloud later)
- Backend: Postgres (`secforge-teleport-db` from Phase 1)
- Public hostname: tp.secforge.local
- OIDC federation to Keycloak `platform` realm
- Roles:
  - `viewer`: read-only kubectl, no exec, no DB
  - `developer`: kubectl read + namespace-scoped write to non-platform namespaces, DB read on app DBs
  - `admin`: full kubectl, DB read/write all, hardware FIDO2 REQUIRED for login
- Targets:
  - Kubernetes: the local docker-desktop cluster
  - Database: secforge-app Postgres (and others as needed)
- Session recording: to MinIO bucket `teleport-recordings`

## Phase 8.2 — Deploy Teleport

Use the official Helm chart `teleport-cluster`:
- 1 auth replica
- 1 proxy replica
- Postgres backend with TLS
- Cert from cert-manager (mkcert-issuer)
- Public hostname `tp.secforge.local`
- ACME disabled (we use mkcert)
- Resource limits: 512Mi memory, 500m CPU
- SPIFFE-CSI volume; identity = `spiffe://secforge.local/ns/teleport/sa/teleport`

## Phase 8.3 — Configure OIDC federation

Create Keycloak client `teleport` in `platform` realm:
- Confidential
- Redirect URI `https://tp.secforge.local/v1/webapi/oidc/callback`
- Mapper: include realm roles in token

In Teleport, create OIDCConnector:
```yaml
kind: oidc
version: v3
metadata:
  name: keycloak
spec:
  redirect_url: https://tp.secforge.local/v1/webapi/oidc/callback
  client_id: teleport
  client_secret: <from-keycloak>
  issuer_url: https://auth.secforge.local/realms/platform
  scope: [openid, email, profile, roles]
  claims_to_roles:
    - claim: realm_access.roles
      value: platform_admin
      roles: [admin]
    - claim: realm_access.roles
      value: platform_developer
      roles: [developer]
    - claim: realm_access.roles
      value: platform_viewer
      roles: [viewer]
```

## Phase 8.4 — Configure roles

`viewer.yaml`, `developer.yaml`, `admin.yaml` Teleport Role resources. The `admin` role MUST require hardware FIDO2 (Teleport per-session MFA setting + role-level required `webauthn` second factor).

Example admin role (excerpt):
```yaml
kind: role
version: v7
metadata:
  name: admin
spec:
  options:
    require_session_mfa: hardware_key_touch
    max_session_ttl: 4h
    record_session:
      desktop: true
      ssh: true
      kubernetes: true
  allow:
    kubernetes_groups: [system:masters]
    kubernetes_users: ['{{external.email}}']
    db_labels: { '*': '*' }
    db_users: [postgres]
```

## Phase 8.5 — Register Kubernetes target

Register the local docker-desktop cluster as a Teleport Kubernetes resource:
- Generate join token from Teleport
- Run `teleport-kube-agent` Helm chart in the local cluster, joining with the token

After registration, `tsh kube ls` shows `secforge-local` and `tsh kube login secforge-local` configures kubectl.

## Phase 8.6 — Register database target

Use Teleport Database Service to register Postgres:
- secforge-app Postgres
- secforge-keycloak Postgres (for emergency access only — typical app shouldn't go here)
- Register with TLS

After registration, `tsh db ls` shows them; `tsh db connect secforge-app` opens a psql session.

## Phase 8.7 — Configure session recording to MinIO

Teleport S3 backend, pointed at our MinIO:
```yaml
recording:
  audit_sessions_uri: s3://teleport-recordings/?endpoint=minio.minio.svc.cluster.local:9000&disablesse=true&insecure=false&use_fips_endpoint=false
```

Use the MinIO credentials stored in OpenBao (Phase 5).

## Phase 8.8 — Test the full flow

1. `tsh login --proxy=tp.secforge.local --auth=keycloak`
2. Browser opens, Keycloak passkey prompt
3. After successful auth, Teleport prompts for hardware key tap (admin role)
4. `tsh kube login secforge-local`
5. `kubectl get pods -A` works through Teleport
6. `tsh db connect secforge-app`
7. Open the Web UI at https://tp.secforge.local/web
8. Verify session is being recorded — playback works

## Phase 8.9 — Lock down direct access

Now that Teleport works, document the policy:
- Direct kubectl access (the `kubeconfig` Docker Desktop installs) remains usable locally for convenience
- For staging/prod (when those exist), direct access is removed; only Teleport-issued cert works
- Document this in docs/04-security/access-policy.md

## Phase 8.10 — Documentation

Update:
- docs/01-architecture/09-privileged-access.md
- docs/03-runbooks/teleport-operations.md
- docs/03-runbooks/teleport-recovery.md (if Teleport itself is down — what's the break-glass?)
- docs/04-security/access-policy.md
- docs/02-decisions/0007-teleport-community-edition.md

## Constraints

- Hardware FIDO2 REQUIRED for admin role
- Session recording enabled for kubectl exec, SSH, DB sessions
- No long-lived kubeconfig once Teleport is the access path (locally we keep it; document)
- Recordings stored in MinIO for now; Object Lock equivalent is a documented gap
- All audit events stream to Wazuh (configure the Teleport audit log forwarder)
```

---

## Success criteria

- [ ] Teleport deployed, healthy, reachable at https://tp.secforge.local
- [ ] OIDC federation to Keycloak works
- [ ] Three roles defined; hardware FIDO2 enforced for admin
- [ ] Local Kubernetes cluster registered
- [ ] At least one Postgres database registered
- [ ] Session recording to MinIO verified (playback works)
- [ ] Documentation and ADR updated; PLAN.md updated

---

## Troubleshooting

### "OIDC login fails — issuer mismatch"
Keycloak's discovery URL must exactly match `issuer_url` in OIDCConnector, including trailing slash conventions.

### "Hardware key not detected"
WebAuthn requires HTTPS. Verify `tp.secforge.local` resolves to your local cluster and the cert is browser-trusted.

### "Session recording fails to upload"
MinIO credentials wrong or `audit_sessions_uri` malformed. Check MinIO console; recordings should appear under teleport-recordings/sessions/.

---

## What's next

[Phase 9 — Hello World end-to-end](./phase-09-hello-world.md).
