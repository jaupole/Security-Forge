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

## Phase 8b — Teleport deploy + targets + verification

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

3. **Three Teleport role definitions:**
   - `viewer.yaml`: read-only kubectl, no exec, no DB.
   - `developer.yaml`: namespace-scoped write to non-platform
     namespaces; DB read on `secforge-app`.
   - `admin.yaml`: full kubectl, DB read+write all targets,
     `require_session_mfa: hardware_key_touch`, max_session_ttl 4h.

4. **Kubernetes target** registration via `teleport-kube-agent` chart
   (joins to the auth server with a stored token).

5. **Database targets:**
   - `secforge-app` (developer + admin reachable).
   - `secforge-keycloak` (admin only, break-glass).

6. **End-to-end test** (operator-driven, requires hardware key):
   - `tsh login --proxy=tp.secforge.local --auth=keycloak`
   - Browser → Keycloak SSO → assigned `platform_admin` realm role
   - Hardware key tap on session start
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

- [ ] Hardware FIDO2 key plugged in and registered as a Keycloak passkey
      OR enrolled as a Teleport-side hardware key.
- [ ] `tsh` CLI installed on the operator's machine
      (`brew install --cask teleport-suite` on macOS, etc.).
- [ ] Browser trusts the mkcert local CA (already true if you've used
      any other `*.secforge.local` URL).
- [ ] Operator user exists in Keycloak `platform` realm with at least
      one of the three new realm roles assigned.

## Why direct kubectl stays usable in local edition

Phase 8b explicitly does NOT remove the operator's local kubeconfig
(the one Docker Desktop installs). Reason: convenience for the
part-time operator. Production removes it. See
[docs/04-security/access-policy.md](../../docs/04-security/access-policy.md)
for the local-vs-prod delta — written in 8b.
