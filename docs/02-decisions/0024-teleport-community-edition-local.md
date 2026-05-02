# ADR-0024: Teleport Community Edition for privileged access (Local Edition)

**Status**: Accepted
**Date**: 2026-05-02
**Decision-makers**: Project owner
**Phase**: 8 (8a foundation)

## Context

Phase 8 introduces a privileged-access broker between human admins and the
platform's sensitive surfaces (kubectl on the local cluster, Postgres
admin sessions). The architecture commits to:

- **OIDC-federated SSO** for human authentication (Keycloak `platform`
  realm; same auth path as Grafana + Wazuh dashboards).
- **Hardware FIDO2** required for the highest-privilege role.
- **Centralised session recording** (kubectl exec, db sessions) so the
  blast-radius of a compromised admin credential is auditable
  retroactively.
- **Cert-based access** that rotates faster than user-issued credentials
  — no long-lived static kubeconfigs handed out by-hand.

Build-vs-buy options on the table:

1. **Skip the broker, rely on direct kubectl** (Docker Desktop ships a
   kubeconfig the operator already has). Acceptable for solo local-dev,
   but defers the production-realistic pattern.
2. **Bastion host with manual session-recording** (e.g. ssh + asciinema
   + ad-hoc audit). Custom; doesn't scale; doesn't federate to OIDC.
3. **Teleport** (community or enterprise edition).
4. **Boundary** (HashiCorp). Overlaps Teleport's role but is more
   network-broker-shaped and less batteries-included for cert-based
   kubectl + DB.
5. **HashiCorp Vault SSH/PKI** issuing per-session kubectl certs,
   without a UI/session-recording layer. Lightweight; doesn't give us
   recording.

The CLAUDE.md commit-list names **Teleport Community** for this layer
(see "Privileged Access" row), which already locks the choice — this
ADR records the rationale + the local-edition-specific shape.

## Decision

**Deploy Teleport Community Edition (Apache 2.0) as the privileged-access
broker for human admin sessions targeting the Kubernetes cluster and
the in-cluster Postgres databases. Federate to Keycloak for SSO. Enforce
hardware FIDO2 on the `admin` role. Stream session recordings to MinIO.**

Specifically:

| Property | Value |
|---|---|
| Edition | Community Edition (open-source, Apache 2.0; no per-seat cost; covers all features needed for local + small-team production) |
| Topology | Auth + Proxy on a single replica (HA = future cloud edition decision) |
| Backend | Postgres (`secforge-teleport-db` in `teleport` ns; mirrors the chart's expected backend shape) |
| Public hostname | `tp.secforge.local` (mkcert-issued cert) |
| OIDC IdP | Keycloak `platform` realm; client `teleport` |
| Roles | `viewer` (read-only), `developer` (namespace-scoped write + DB read), `admin` (full + hardware FIDO2 required) |
| Targets registered | Local Kubernetes cluster (`secforge-local`), `secforge-app-db` Postgres, `secforge-keycloak-db` Postgres (break-glass only) |
| Session recording | MinIO bucket `teleport-recordings`; scoped MinIO user with bucket-only policy |
| MFA enforcement | TOTP-via-Keycloak SSO assertion (no Teleport-side per-session re-prompt); compensated by tight session TTLs (`admin` 8h max + 4h idle, `developer` 12h + 4h idle, `viewer` 24h + 8h idle). See § "MFA posture (TOTP, not hardware FIDO2)" below. |
| SPIFFE identity | `spiffe://secforge.local/ns/teleport/sa/teleport` (auth-pod side) |

## Rationale

### Why Teleport Community over Enterprise

Community Edition covers every Phase 8 deliverable:
- OIDC federation
- Per-session MFA / hardware-key touch
- Kubernetes resource broker (`tsh kube login`)
- Database resource broker (`tsh db connect`)
- Session recording with playback
- Audit log emission for SIEM ingestion (Wazuh side, deferred to 7d
  follow-up)

Enterprise adds:
- SAML federation (we use OIDC — irrelevant)
- Cluster-wide RBAC across multiple Teleport clusters (single cluster
  here)
- Access requests with approval workflows (single-operator local-edition;
  the "approval workflow" is the operator's own discretion)
- Higher-tier support (we're not buying support for local-edition)

Net: Enterprise pays for nothing we use locally, and the production
migration story stays the same (re-deploy chart with cloud-tier values).

### Why a single replica locally

Teleport's HA story is the auth+proxy pair scaled horizontally with a
shared backend. On a single Docker Desktop node, more replicas means
more memory pressure for zero availability gain (the node is the
single point of failure). The chart deploys a single auth + single
proxy; cloud edition increases this in cloud-region multi-node deploys.

### Why Postgres backend (not the bundled etcd-style key-value)

Teleport's chart supports two backends locally: SQLite (one-pod-only)
and PostgreSQL. We pick Postgres because:

- We already operate CNPG-managed Postgres clusters (Phase 1 pattern;
  see [ADR-0003](./0003-cloudnativepg-vs-others.md)) — adding one more
  is operationally trivial.
- Postgres survives pod restart with full state (SQLite-on-PVC also
  does, but ties Teleport to the same pod identity).
- Production-realistic: cloud Teleport deploys typically use Postgres
  or DynamoDB, never SQLite.

The cluster `secforge-teleport-db` mirrors the existing CNPG patterns
(`enableSuperuserAccess: false`, scram-sha-256 password encryption,
mkcert-issued TLS for in-cluster connections).

### Why mkcert TLS for `tp.secforge.local`

Same trust model as every other in-platform UI hostname (auth, app, pf,
pt, pm, grafana, wazuh, openbao, tempo, loki). The browser already
trusts the mkcert local CA on the operator's machine; no Let's Encrypt
or external CA needed. Cloud edition swaps in cert-manager + Let's
Encrypt issuer (or whatever the cloud's regional CA is) at promotion
time — chart values change, no architecture change.

### MFA posture (TOTP, not hardware FIDO2)

The original Phase 8 prompt called for `require_session_mfa:
hardware_key_touch` on the `admin` role. **For local edition we drop
that** and inherit ADR-0007's TOTP-via-Keycloak posture, with
tightened session TTLs as the compensating control.

Reasoning:

- **No hardware FIDO2 key available on the local-dev workstation today.**
  ADR-0007 already accepted TOTP as the interim primary factor for
  every admin login on the `platform` realm (Keycloak admin console,
  OpenBao OIDC, Grafana, Wazuh dashboard). Adding Teleport as the
  ONE consumer that requires hardware FIDO2 creates an asymmetric
  posture — operator can admin every other component with TOTP but
  not the access broker — that doesn't reduce blast radius (the
  TOTP-only admins still have full kubectl + DB access via direct
  paths).
- **Local-edition threat model is single-tenant dev.** The TOTP-
  vs-hardware-tap delta defends against credential phishing, which
  isn't a meaningful threat against a single operator's local
  workstation that never accepts inbound auth flows.
- **Production VPS / cloud edition cuts over to hardware FIDO2** at
  the same moment ADR-0007's revert-to-passkeys clause fires. Teleport's
  `admin` role gets `require_session_mfa: hardware_key_touch` re-added
  in the cloud-edition values overlay, no architecture change.

**Compensating controls in lieu of per-session hardware tap:**

| Role | Max session TTL | Idle timeout |
|---|---|---|
| `admin` | 8h | 4h |
| `developer` | 12h | 4h |
| `viewer` | 24h | 8h |

The 8h `admin` ceiling forces re-auth via Keycloak SSO (which involves
TOTP) at least once per shift; the 4h idle timeout caps the residual
risk of an unattended laptop. These are stricter than Teleport's
defaults (12h max, no idle by default).

The Keycloak `platform` realm itself enforces TOTP as the secondary
factor on every login (per the realm config from Phase 3 + ADR-0007).
So the practical login flow is: `tsh login --proxy=tp.secforge.local
--auth=keycloak` → browser → Keycloak username+password+TOTP →
Teleport receives the SSO assertion → cert issued. No additional
Teleport-side MFA prompt. Operationally light, matches Grafana/Wazuh
SSO flows.

Cross-references:
- [ADR-0007 § Amendment 2026-05-02 — Teleport adopts TOTP posture](./0007-totp-instead-of-passkeys-locally.md)
  documents the same decision from ADR-0007's side.
- [`docs/06-reference/migration-to-vps.md` § Phase C Phase 3](../06-reference/migration-to-vps.md)
  is the production-cutover trigger for hardware-FIDO2 enforcement.

### Why MinIO for session recording

Phase 6.2 already deployed MinIO as the local S3 substitute (Phase 5
follow-up wiring; Phase 7.4/7.5 wired Loki + Tempo MinIO storage). Reusing
MinIO for session recording:

- Same operational shell (admin + scoped users + bucket policies +
  VSO-rendered K8s Secrets).
- Cloud migration path is identical to Loki + Tempo: re-point the chart
  values at cloud S3 (or whatever the region offers).
- No new component on the platform's local resource budget.

The bucket `teleport-recordings` will have a scoped MinIO user
(`teleport-sessions`) with bucket-only policy; creds live at
`secret/data/minio/teleport/credentials` and render via VSO into the
`teleport` ns (same pattern as the loki/tempo MinIO bindings from
Phase 7.4/7.5).

**Object Lock equivalent (immutable session recordings) is a documented
gap.** MinIO supports object lock; configuring it adds operational
complexity (lock retention modes, governance / compliance distinction).
Defer to cloud-edition where we'll use S3 Object Lock or its cloud-
specific equivalent. Note this in the runbook so an operator
understands a compromised admin can't quietly delete their own session
recording in this configuration — they could, theoretically, in
local-edition.

### Why direct kubectl access stays usable locally

Phase 8 does NOT remove the operator's local kubeconfig (the one
Docker Desktop installs). Reason: convenience for the part-time
operator. Production removes it (only Teleport-issued certs work).
Documented in [`docs/04-security/access-policy.md`](../04-security/
access-policy.md) as a local-vs-prod delta.

## Slot-numbering note (collision with prompt-doc)

The Phase 8 prompt doc references ADR-0006 (skip-Teleport-locally) and
ADR-0007 (Teleport-Community-Edition). Both slot numbers are already
taken:

- ADR-0006 = Keycloak realm signing keys (local edition)
- ADR-0007 = TOTP instead of passkeys for local development

Per the project's append-only ADR rule, this ADR claims the next
available slot (**0024**). The Phase 8 prompt-doc will be updated to
reference 0024 in the same commit batch as this ADR. The "skip
Teleport" ADR is not written because the operator is not skipping;
if a future operator chooses to skip, they should claim the next
available slot at that time and write the rationale + gaps.

## Consequences

### What this commits us to

- Operating one more Postgres cluster (`secforge-teleport-db`) — one
  more `kubectl get cluster` row, one more `cnpg cluster status`
  consideration during a recovery scenario.
- A second `platform`-realm OIDC client + 3 realm roles
  (`platform_admin`, `platform_developer`, `platform_viewer`). Same
  shape as the openbao + grafana + wazuh-dashboard clients already in
  this realm.
- Operator's Keycloak `platform` realm user has TOTP enrolled — same
  as every other platform admin login (no new factor to provision).
  Hardware-FIDO2 enrollment is deferred to the production VPS / cloud
  cutover trigger documented in `migration-to-vps.md`.
- Session recordings consume MinIO storage; size grows with admin
  activity. Quota check + retention policy is operator-time work.

### What this preserves

- Cloud migration is configuration-only: chart values update for
  hostname (cloud LB) + cert (cloud-issued) + backend (cloud-managed
  Postgres or DynamoDB) + session recordings (cloud S3 with Object
  Lock). Roles, OIDC connector, FIDO2 enforcement carry forward
  unchanged.
- The single-tenant local cluster gets the same access pattern that a
  multi-developer cloud cluster will use, building muscle memory now.

### Known local gaps

1. **Object Lock on session recordings.** MinIO supports it; we don't
   configure it for local edition. Compromised admin can theoretically
   delete their own recordings.
2. **Single-replica auth+proxy.** Loss of the auth pod = no Teleport
   logins until it recovers. Operator can fall back to direct
   kubeconfig for local recovery; production removes that fallback.
3. **No automatic Wazuh-side audit log forwarding** (Phase 7d.2's
   syslog forwarding deferred). Teleport's audit events live in the
   manager's Postgres backend + the local audit log; SIEM ingestion
   is a follow-up.

## Re-evaluation criteria

Re-open this ADR if:

1. Teleport Community changes license (currently Apache 2.0; SaaS
   pivots from upstream Gravitational have happened in the broader
   ecosystem; check before each major version bump).
2. The single-replica posture stops being acceptable (multi-developer
   local cluster, or cloud migration imminent).
3. A bastion alternative (Boundary, custom SSO-cert mint) becomes
   compelling enough to revisit; specifically if the team finds
   Teleport's role-config opacity painful or its session-recording
   replay surface too thin.
4. Hardware FIDO2 enforcement becomes a friction blocker (e.g., the
   user loses their key and can't admin) — at which point the answer
   is "register a backup key", not "lower the role's MFA bar."

## References

- [docs/01-architecture/09-privileged-access.md](../01-architecture/09-privileged-access.md) — phase 8a design (this commit).
- [docs/05-claude-code-prompts/phase-08-teleport.md](../05-claude-code-prompts/phase-08-teleport.md) — phase prompt (will be updated to reference this ADR).
- [ADR-0003](./0003-cloudnativepg-vs-others.md) — CNPG choice (Postgres backend uses the same pattern).
- [ADR-0007](./0007-totp-instead-of-passkeys-locally.md) — TOTP-vs-passkeys interim decision; Teleport's hardware-FIDO2 enforcement is independent of the realm's primary-factor choice.
