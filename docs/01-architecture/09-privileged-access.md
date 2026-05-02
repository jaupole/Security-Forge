# Privileged Access (Local Edition)

> Decision record: [ADR-0024 — Teleport Community Edition for privileged access (Local Edition)](../02-decisions/0024-teleport-community-edition-local.md)
> Phase: 8 (8a foundation, 8b Teleport deploy + targets + verification)

## Goals

- Centralised, OIDC-federated privileged access to the platform's
  sensitive surfaces (kubectl on the local cluster, Postgres admin
  sessions on `secforge-app` + `secforge-keycloak`).
- Hardware FIDO2 second-factor required for the highest-privilege
  role (`admin`) — non-negotiable on this layer even though the
  user-tenant realm runs TOTP per ADR-0007.
- Centralised session recording (kubectl exec, db sessions) so
  compromise of an admin credential is auditable retrospectively.
- Cert-based access that rotates faster than user-issued static
  kubeconfigs — no long-lived configs handed out by-hand.
- A pattern that survives cloud migration with chart-values changes
  only — no architecture change at promotion time.

## Topology

```
                    ┌────────────────────────────────────┐
                    │          Browser / tsh CLI         │
                    └──────────────┬─────────────────────┘
                                   │ HTTPS (mkcert TLS)
                                   ▼
                    ┌────────────────────────────────────┐
                    │   tp.secforge.local (port 443)     │
                    │       Teleport Proxy + Auth        │
                    │   (single replica, auth + proxy    │
                    │    in one pod for local edition)   │
                    └──────────────┬─────────────────────┘
                                   │
                ┌──────────────────┼──────────────────────┐
                │                  │                      │
                ▼                  ▼                      ▼
       ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐
       │ Keycloak OIDC  │  │   CNPG cluster │  │     MinIO        │
       │ platform realm │  │ secforge-tele- │  │   bucket:        │
       │ client=teleport│  │   port-db      │  │ teleport-record- │
       │                │  │  (state)       │  │   ings           │
       └────────────────┘  └────────────────┘  └──────────────────┘
                │                                       ▲
                │                                       │ session
                │                                       │ playback
                ▼
       ┌────────────────────────────────────────────────────────────┐
       │                      Targets                                │
       │  - Kubernetes: secforge-local (kube-agent registers)       │
       │  - Database:   secforge-app   (db service registers)        │
       │  - Database:   secforge-keycloak  (break-glass; admin only) │
       └────────────────────────────────────────────────────────────┘
```

The Teleport pod has a SPIFFE-CSI socket so its identity is
`spiffe://secforge.local/ns/teleport/sa/teleport`. That identity
authenticates to OpenBao for any future dynamic-cred reads (e.g., DB
service connecting to target databases).

## Roles

Three Teleport roles map to three Keycloak realm roles via the
OIDCConnector's `claims_to_roles`:

| Realm role | Teleport role | Capabilities |
|---|---|---|
| `platform_viewer` | `viewer` | `kubectl get/describe` cluster-wide; no exec; no DB |
| `platform_developer` | `developer` | `kubectl read` + namespace-scoped write to non-platform namespaces (excludes `kube-system`, `cert-manager`, `kyverno`, `istio-system`, `spire`, `openbao`, `vault-secrets-operator`, `keycloak`, `wazuh`, `wazuh-agent`, `teleport`, `observability`, `minio`, `postgres-operator`); DB read on `secforge-app`'s app DBs |
| `platform_admin` | `admin` | full kubectl (system:masters group); DB read+write on all targets |

The `developer` role's namespace-write exclusion list is the platform's
infrastructure namespaces — operator-managed components stay out of
developer reach. Application namespaces (`app` and any future tenant
namespaces) are reachable for write.

**MFA posture for the `admin` role: TOTP-via-Keycloak SSO + tightened
session TTLs** (NOT hardware-FIDO2 per-session — see [ADR-0024 § MFA
posture](../02-decisions/0024-teleport-community-edition-local.md) and
the [ADR-0007 amendment](../02-decisions/0007-totp-instead-of-passkeys-locally.md#amendment-2026-05-02--teleport-adopts-the-same-totp-posture)).
The realm enforces TOTP as the secondary factor on every login;
Teleport accepts the resulting SSO assertion without an additional
per-session MFA prompt. Tight TTLs do the assurance lifting:

| Role | Max session TTL | Idle timeout |
|---|---|---|
| `admin` | 8h | 4h |
| `developer` | 12h | 4h |
| `viewer` | 24h | 8h |

The 8h `admin` ceiling forces re-auth via Keycloak SSO (which involves
TOTP) at least once per shift; the 4h idle timeout caps the residual
risk of an unattended laptop. These are stricter than Teleport's
defaults (12h max, no idle by default).

When the production-hardening trigger fires (per ADR-0007's revert
clause), the cloud-edition values overlay re-adds
`require_session_mfa: hardware_key_touch` to the `admin` role in
lockstep with the realm's revert-to-passkeys flip.

## Authentication flow

```
  1. User runs `tsh login --proxy=tp.secforge.local --auth=keycloak`
                          │
                          ▼
  2. Browser opens tp.secforge.local/v1/webapi/oidc/login/cli
                          │ → Keycloak redirect
                          ▼
  3. Keycloak presents login UI (username + password + TOTP per
     ADR-0007 — the realm's interim primary-factor choice)
                          │ user authenticates
                          ▼
  4. Keycloak emits ID token with realm_access.roles claim
                          │
                          ▼
  5. Teleport's OIDCConnector maps realm role → Teleport role,
     issues a per-session cert (15min TTL by default, renewable
     up to max_session_ttl — capped at 8h for admin, 12h dev, 24h viewer)
                          │
                          ▼
  6. tsh writes the cert to ~/.tsh/, kubectl/db-clients use it.
     No additional Teleport-side MFA prompt — the Keycloak SSO
     assertion is the MFA-equivalent (it already involved TOTP).
```

The realm-side TOTP posture (ADR-0007) IS the platform's primary-
factor enforcement; Teleport inherits it via OIDC SSO without
duplicating the prompt. The reversal to hardware FIDO2 happens at
the realm level (ADR-0007's revert clause) at production-hardening
time; Teleport's `admin` role gets `require_session_mfa:
hardware_key_touch` added in the cloud-edition values overlay at
the same flip.

## Targets

### Kubernetes (`secforge-local`)

- Registered via the `teleport-kube-agent` Helm chart deployed in the
  same cluster (Phase 8b).
- Joins to the auth server via a long-lived join token stored in OpenBao
  at `secret/data/teleport/kube-agent-join-token`.
- After `tsh kube login secforge-local`, kubectl traffic is brokered
  through Teleport (recorded for `kubectl exec`).

### Database — `secforge-app`

- Registered via Teleport's database service.
- TLS to the CNPG cluster's app endpoint (`secforge-app-db-rw.app.svc:5432`).
- After `tsh db connect secforge-app`, a TLS-tunnelled psql session
  opens; queries are recorded.

### Database — `secforge-keycloak` (break-glass)

- Registered as a target accessible only to the `admin` role.
- Reason: the Keycloak DB is sensitive (realm signing keys live there);
  no normal operator workflow should query it. Break-glass only.

## Session recording

- Storage: MinIO bucket `teleport-recordings` (created in Phase 8a).
- Auth: scoped MinIO user `teleport-sessions` with bucket-only policy
  (no list/read on other buckets); creds at
  `secret/data/minio/teleport/credentials` rendered into a K8s Secret
  in `teleport` ns by VSO (mirror of Loki/Tempo MinIO patterns).
- Format: Teleport's native session-recording format; playback via
  the Web UI at `https://tp.secforge.local/web`.
- Retention: defaults to indefinite (no Teleport-side retention policy
  configured). Operator-managed via MinIO bucket lifecycle policy if
  needed.

**Known gap:** MinIO Object Lock equivalent (immutable recordings) is
NOT configured for local edition (see ADR-0024 § Known local gaps).
A compromised admin credential can theoretically delete its own
session recordings via direct MinIO API access. Cloud edition uses
S3 Object Lock (or equivalent) to close this gap.

## What's at `tp.secforge.local`

| URL | What it serves |
|---|---|
| `https://tp.secforge.local/` | Teleport Web UI (login, kube console, db console, session playback) |
| `https://tp.secforge.local/v1/webapi/oidc/callback` | OIDC callback for `tsh login` browser flow |
| `https://tp.secforge.local:3023` | Teleport SSH proxy port (not used in local edition; included for future hosts) |
| `https://tp.secforge.local:3026` | Teleport Kubernetes proxy port (used by `tsh kube login`) |
| `https://tp.secforge.local:3027` | Teleport database proxy port (used by `tsh db connect`) |

In single-pod auth+proxy mode the chart binds each port on the same
service. Ingress-nginx routes `tp.secforge.local` to the Teleport
service via the standard mkcert-cert ingress pattern.

## Local-vs-cloud delta

| Aspect | Local | Cloud |
|---|---|---|
| Hostname | `tp.secforge.local` (mkcert) | regional cluster URL (cert-manager + Let's Encrypt or cloud CA) |
| Replicas | 1 auth + 1 proxy in one pod | N auth + N proxy across AZs |
| Backend | CNPG `secforge-teleport-db` (single instance) | RDS/Cloud SQL Postgres (multi-AZ) |
| Session storage | MinIO `teleport-recordings` | S3 `teleport-recordings` with Object Lock |
| Direct kubectl | Operator's local kubeconfig still works | Removed; only Teleport-issued certs valid |
| Hardware FIDO2 | Required for `admin` (your existing keys) | Required for `admin` (production keys, separate enrolment) |

Promotion to cloud is configuration-only — no architecture change.

## What remains for Phase 8b

8a (this commit) lays the foundation:
- ADR-0024 (this decision)
- This architecture doc
- `secforge-teleport-db` CNPG cluster
- MinIO bucket + scoped user + VSO binding
- Keycloak `teleport` client + 3 realm roles
- mkcert cert for `tp.secforge.local`
- `teleport` namespace + RBAC scaffolding

8b deploys Teleport and exercises the access pattern:
- Helm release of `teleport-cluster` chart (single replica, Postgres
  backend, MinIO session recording)
- OIDCConnector wiring to Keycloak
- Three role definitions (viewer/developer/admin) including the
  `admin` role's `require_session_mfa: hardware_key_touch`
- Kubernetes target via `teleport-kube-agent`
- Database target for `secforge-app`
- End-to-end test (operator runs `tsh login` + browser SSO + hardware
  tap; verifies session recording lands in MinIO; verifies playback
  works from Web UI)
- Operations runbook + recovery runbook
