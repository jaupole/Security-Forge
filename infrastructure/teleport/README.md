# Teleport (Phase 8 — Privileged Access)

> Decision: [ADR-0024 — Teleport Community Edition for privileged access (Local Edition)](../../docs/02-decisions/0024-teleport-community-edition-local.md)
> Architecture: [docs/01-architecture/09-privileged-access.md](../../docs/01-architecture/09-privileged-access.md)
> Phase prompt: [docs/05-claude-code-prompts/phase-08-teleport.md](../../docs/05-claude-code-prompts/phase-08-teleport.md)

## Phase 8a — Foundation (this directory + companion changes)

What 8a ships (this commit batch):

| File / change | Purpose |
|---|---|
| `infrastructure/cloudnativepg/clusters/teleport-db.yaml` | Namespace `teleport` (PSS=restricted) + ResourceQuota + LimitRange + CNPG cluster `secforge-teleport-db`. Already on disk; this commit updates the deprecated ADR-0006 reference. |
| `infrastructure/teleport/01-vso-binding.yaml` | SA `teleport-vso` + VaultAuth `default` + 2× VaultStaticSecret rendering `teleport-oidc-vso` (Keycloak client_secret) and `teleport-minio-vso` (scoped MinIO creds) into the `teleport` ns. |
| `infrastructure/teleport/02-certificate.yaml` | mkcert-issued Certificate for `tp.secforge.local` + in-cluster Service DNS SANs. Rendered Secret: `tp-secforge-local-tls`. |
| `infrastructure/teleport/apply-minio-user.sh` | Provisions MinIO user `teleport-sessions` with bucket-only policy on `teleport-recordings`; persists creds at `secret/data/minio/teleport/credentials`. (Bucket itself was already provisioned by `infrastructure/minio/bucket-bootstrap-job.yaml` with versioning + GOVERNANCE Object Lock @ 90d.) |
| `infrastructure/keycloak/clients/teleport.sh` | Provisions OIDC client `teleport` in `platform` realm + 3 realm roles (`platform_admin`, `platform_developer`, `platform_viewer`); persists client_secret + issuer + redirect_uri at `secret/data/teleport/oidc`. |
| `infrastructure/openbao/policies/vso.hcl` | Adds read on `secret/{data,metadata}/{teleport/oidc, minio/teleport/credentials}`. |
| `infrastructure/vault-secrets-operator/configure-openbao-role.sh` | Adds `teleport-vso` K8s auth role bound to `teleport` ns. |
| `docs/02-decisions/0024-teleport-community-edition-local.md` | ADR for the Teleport CE choice + local-edition shape. |
| `docs/01-architecture/09-privileged-access.md` | Architecture doc: topology, role mapping, OIDC flow, target list, session-recording, local-vs-cloud delta. |

After this commit batch the cluster has:

- ✅ `teleport` namespace + Postgres backend (`secforge-teleport-db-1` Ready)
- ✅ Keycloak `teleport` client + 3 realm roles in `platform` realm
- ✅ MinIO bucket + scoped user + creds in OpenBao
- ✅ VSO renders `teleport-oidc-vso` + `teleport-minio-vso` Secrets in `teleport` ns
- ✅ TLS cert `tp-secforge-local-tls` Ready

## Phase 8b — Teleport deploy (WIP — stopped at auth-config validation blocker)

**Status (2026-05-02):** manifests drafted; helm release attempted +
uninstalled cleanly; resuming next session.

| File / change | Drafted | Applied |
|---|---|---|
| `03-helm-values.yaml` | ✅ | ❌ (helm release uninstalled after debug) |
| `04-oidc-connector.yaml` | ✅ | ❌ (depends on auth pod healthy) |
| `05-roles.yaml` | ✅ | ❌ (depends on operator pod healthy) |

**Blockers hit during 8b:**

1. **`cannot disable multi-factor authentication`** — Teleport auth
   pod refuses to start with our authentication config. Combinations
   tried: `local_auth: false` + `second_factor: off` (forbidden as
   expected — that's the documented invalid combo); `local_auth:
   false` + `second_factor: optional` (still forbidden); `local_auth:
   true` + `second_factor: optional` (STILL forbidden). The chart
   auto-injected `webauthn` block (with `rp_id` initially set to the
   cluster name, fixed by us to `tp.secforge.local`) didn't resolve
   it. Fresh-PVC redeploys didn't clear it either, so it's not
   persisted-bad-state from an earlier attempt. Worth investigating
   v18.x source for stricter validation than the chart docs imply.

2. **Proxy `x509: certificate signed by unknown authority`** —
   Teleport's proxy validates the cert chain at startup and rejects
   our mkcert-signed cert because the mkcert local CA isn't in the
   pod's trust store. Same trust-store issue every other
   `*.secforge.local`-hosting pod has solved (Keycloak, Grafana,
   Wazuh dashboard). Fix: add `tls.existingCASecretName` (or env
   `SSL_CERT_FILE` mounted volume) pointing at the mkcert root CA.

3. **PVC accidentally wiped** during debug iteration — `kubectl
   delete pvc -n teleport --all` was over-broad and took down
   `secforge-teleport-db-1`'s PVC alongside the chart's PVC. CNPG
   fully recovered (no data loss; nothing was using the cluster yet
   — Teleport runs on PVC-SQLite per ADR-0024, not Postgres).
   Lesson logged: scope `kubectl delete` to label selectors on
   multi-tenant namespaces.

**To resume next session:**

1. Add CA trust mount to `03-helm-values.yaml` so the proxy can
   validate `tp-secforge-local-tls`. Pattern to mirror: how the
   Wazuh dashboard or Grafana pods trust the mkcert local CA today.
2. Investigate the "cannot disable multi-factor authentication"
   error against Teleport v18.x source. Likely workaround: enable
   Teleport-native TOTP (`second_factor: otp`) as the registered
   second factor — local users still don't exist (OIDC is the only
   login flow), but the validation framework is satisfied. Update
   ADR-0024 § MFA posture to reflect this if it works.
3. Once auth pod is healthy: apply `04-oidc-connector.yaml` +
   `05-roles.yaml` via the operator (auto-reconciles via tctl).
4. Continue to 8b.3 (kube-agent), 8b.4 (DB targets), 8b.5 (e2e
   test), 8b.6 (runbooks), 8b.7 (PLAN.md flip).

---

## Phase 8b — Teleport deploy + targets + verification (original plan)

8b is a focused follow-up session that:

1. **Helm release** `teleport-cluster` chart in `teleport` ns:
   - Single auth + proxy replica.
   - Postgres backend pointing at `secforge-teleport-db-rw.teleport.svc:5432`
     (db creds from `secforge-teleport-db-app` Secret).
   - Public hostname `tp.secforge.local`; TLS from
     `tp-secforge-local-tls` Secret.
   - Session recording → MinIO; creds from `teleport-minio-vso`.
   - SPIFFE-CSI volume; identity
     `spiffe://secforge.local/ns/teleport/sa/teleport`.

2. **OIDCConnector** wired to Keycloak `platform` realm:
   - Client_id + client_secret from `teleport-oidc-vso`.
   - Issuer from `teleport-oidc-vso`.
   - `claims_to_roles` mapping `realm_access.roles` → Teleport roles
     (platform_admin → admin, platform_developer → developer,
     platform_viewer → viewer).

3. **Three Teleport role definitions** (max_session_ttl + idle_timeout
   per [ADR-0024 § MFA posture](../../docs/02-decisions/0024-teleport-community-edition-local.md) and [ADR-0007 amendment](../../docs/02-decisions/0007-totp-instead-of-passkeys-locally.md#amendment-2026-05-02--teleport-adopts-the-same-totp-posture)):
   - `viewer.yaml`: read-only kubectl, no exec, no DB; max 24h, idle 8h.
   - `developer.yaml`: namespace-scoped write to non-platform
     namespaces; DB read on `secforge-app`; max 12h, idle 4h.
   - `admin.yaml`: full kubectl, DB read+write all targets;
     max 8h, idle 4h. **NO `require_session_mfa: hardware_key_touch`**
     for local edition — MFA is realm-side TOTP via OIDC SSO assertion.
     Cloud-edition values overlay re-adds `hardware_key_touch` at the
     production-hardening trigger (ADR-0007's revert clause).

4. **Kubernetes target** registration via `teleport-kube-agent` chart
   (joins to the auth server with a stored token).

5. **Database targets:**
   - `secforge-app` (developer + admin reachable).
   - `secforge-keycloak` (admin only, break-glass).

6. **End-to-end test** (operator-driven, TOTP only — no hardware key):
   - `tsh login --proxy=tp.secforge.local --auth=keycloak`
   - Browser → Keycloak SSO (username + password + TOTP) → assigned
     `platform_admin` realm role
   - Cert issued by Teleport, no additional per-session MFA prompt
     (the Keycloak SSO assertion satisfies Teleport's MFA gate)
   - `tsh kube login secforge-local` + `kubectl get pods -A`
   - `tsh db connect secforge-app` + sample query
   - Verify recording in `teleport-recordings/` MinIO bucket
   - Web UI playback at `https://tp.secforge.local/web`

7. **Operations runbook** (`docs/03-runbooks/teleport-operations.md`):
   - Daily ops: `tsh login` flow, common `tsh` commands,
     joining new agents.
   - Recovery: Teleport itself down → fallback paths
     (operator's local kubeconfig still works on local edition).
   - Cert rotation: cert-manager renews automatically on the
     30-day window.
   - Audit-log forwarding to Wazuh: deferred (current Wazuh stack
     ingests Teleport audit log via the agent's localfile blocks
     once the audit log is mounted to host path; Phase 7d.6 polish).

## Operator pre-checks before running 8b

- [ ] **TOTP enrolled** in your Keycloak `platform` realm user (already
      true if you've ever used `bao login -method=oidc`, the Keycloak
      admin console, Grafana SSO, or Wazuh OIDC). No hardware FIDO2
      needed for local edition — see ADR-0007 amendment.
- [ ] `tsh` CLI installed on the operator's machine
      (`brew install --cask teleport-suite` on macOS;
      [Linux/Windows install docs](https://goteleport.com/docs/installation/)).
- [ ] Browser trusts the mkcert local CA (already true if you've used
      any other `*.secforge.local` URL).
- [ ] Your Keycloak `platform` realm user has at least one of the
      three new realm roles assigned: `platform_admin`,
      `platform_developer`, `platform_viewer`. Admin UI:
      Users → your-user → Role mapping → Assign role → realm role.

## Why direct kubectl stays usable in local edition

Phase 8b explicitly does NOT remove the operator's local kubeconfig
(the one Docker Desktop installs). Reason: convenience for the
part-time operator. Production removes it. See
[docs/04-security/access-policy.md](../../docs/04-security/access-policy.md)
for the local-vs-prod delta — written in 8b.
