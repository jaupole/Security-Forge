# Phase 5 — Secrets Management (OpenBao)

**Status:** ⬜ Not started · ⬜ In progress · ⬜ Complete

**Estimated time:** 2-3 days

**Prerequisites:** Phases 1-4 complete.

⚠️ **OpenBao policy structure sets the tone for least-privilege everywhere.** Take time on this one even locally.

---

## Goal of this phase

Deploy OpenBao with the production seal pattern (Transit auto-unseal, not dev mode). Configure auth methods, secrets engines, and verify a workload can fetch dynamic database credentials.

---

## What you (the human) need to do first

1. Confirm `secforge-openbao-db` Postgres exists.
2. Read the secrets management section of `docs/01-architecture/00-overview.md`.
3. Have your hardware FIDO2 key (or TOTP authenticator app) available — first OpenBao login is via Keycloak.

---

## Keycloak clients required (verify or create BEFORE starting)

OIDC integration in this phase requires a Keycloak client. **Confirm it exists before running the Claude Code prompt** — the prompt's OIDC step will fail if the client isn't in place, and the resulting "Invalid role" / "claim missing" / 403 errors are time-consuming to debug.

| Client ID | Realm | Confidential | Redirect URIs | Created by |
|---|---|---|---|---|
| `openbao` | `platform` | yes (client-secret) | `https://bao.secforge.local/ui/vault/auth/oidc/oidc/callback`, `https://bao.secforge.local/oidc/callback` | This phase. Use `infrastructure/keycloak/clients/openbao.sh` (idempotent, runs kcadm via your master-realm credentials), or create via admin UI per the runbook. |

The client's Default client scopes must include **`roles`** (Keycloak's built-in scope that emits `realm_access.roles` in tokens). The realm-roles mapper on the `roles` scope should have **Add to ID token + Add to userinfo + Add to access token** all ON.

The realm role **`platform_admin`** must exist in the `platform` realm and be assigned to your platform-realm user (so OpenBao's `auth/oidc/role/admin` can bind on it).

If you don't yet have working Keycloak admin credentials (kcadm requires them; the bootstrap-admin path was torn down at end of Phase 3.7), either:
- Use jaupole + master-realm password + a fresh TOTP code with `infrastructure/keycloak/clients/openbao.sh`, OR
- Click through the Keycloak admin UI manually (5 min). Steps in `docs/03-runbooks/openbao-recovery.md` § "Rebuild the seal-OpenBao".

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 5 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-05-openbao.md before doing anything.

Your task is to deploy OpenBao with Transit auto-unseal (production-realistic pattern), configure auth methods, set up secrets engines, and verify dynamic Postgres credentials work.

## Phase 5.1 — Design

Document in docs/01-architecture/05-secrets-management.md:
- Engine: OpenBao 2.x
- Topology: TWO OpenBao instances —
  1. `openbao-seal` — a small, separate OpenBao (1 replica, file storage, Shamir-sealed) that runs only the Transit secrets engine. This acts as the "KMS" for the main OpenBao. Locally, you unseal it manually after each cluster restart with the unseal key.
  2. `openbao` — the main one. Auto-unseals via the Transit engine of `openbao-seal`. Backed by `secforge-openbao-db` Postgres. Used for actual platform secrets.
- This pattern is more complex than dev-mode but teaches the production model. Document the seal-OpenBao itself as a "trusted root" — its compromise compromises everything.
- Auth methods: Kubernetes (workloads), OIDC federated to Keycloak (humans)
- Secrets engines: KV-v2 (static), database (dynamic Postgres creds), Transit (encryption-as-a-service for apps)
- Audit: file device → STDOUT → eventually Wazuh

ADR: docs/02-decisions/0005-openbao-seal-strategy.md — explain the two-instance pattern and why we don't use dev mode.

## Phase 5.2 — Deploy openbao-seal

Smaller, simpler instance:
- Helm chart: openbao/openbao
- 1 replica, integrated Raft storage on a small PVC
- Seal: Shamir (3 of 5 unseal keys)
- ClusterIP service in `openbao` namespace, only reachable by the main openbao
- NetworkPolicy: only main openbao can reach it
- Initialize manually:
  ```
  bao operator init -key-shares=5 -key-threshold=3
  ```
  Capture the 5 unseal keys and the initial root token. Store them OFFLINE (1Password or paper). These are NEVER in any commit, K8s Secret, or environment variable.
- Immediately enable the Transit engine and create a key called `unseal`:
  ```
  bao secrets enable transit
  bao write -f transit/keys/unseal type=aes256-gcm96
  ```
- Create a policy `unseal-policy` allowing only `update` on `transit/encrypt/unseal` and `transit/decrypt/unseal`
- Create a token bound to that policy with TTL 24h, renewable. This token is what the main openbao uses to seal/unseal.

## Phase 5.3 — Deploy main openbao

- Helm chart: openbao/openbao
- 3 replicas in dev (HA, integrated Raft) — yes, even locally, because we want to exercise the Raft setup
- Storage: integrated Raft (NOT Postgres — Postgres backend is deprecated; use Raft and use the RDS for nothing here. Wait, correct that — re-read: integrated Raft is recommended for OpenBao. Postgres can be used but Raft is simpler. Use Raft.)
- Seal config:
  ```
  seal "transit" {
    address = "http://openbao-seal.openbao.svc.cluster.local:8200"
    token = "<from-step-5.2>"
    disable_renewal = "false"
    key_name = "unseal"
    mount_path = "transit/"
  }
  ```
- ClusterIP service; expose UI at `https://bao.secforge.local` via Ingress with NetworkPolicy restricting to localhost only
- Pod identity: `spiffe://secforge.local/ns/openbao/sa/openbao`
- Initialize the main openbao: `bao operator init -recovery-shares=5 -recovery-threshold=3` (recovery, not unseal, because of auto-unseal). Store recovery keys offline.

Note: I gave conflicting advice above. The correct approach is integrated Raft for the main OpenBao too. The Postgres `secforge-openbao-db` we created in Phase 1 can be re-purposed for an audit log offload OR removed. Decide and document. If removed, scale down the Postgres cluster.

## Phase 5.4 — Auth methods

### Kubernetes auth
```
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### OIDC federated to Keycloak
Create a Keycloak client `openbao` in the `platform` realm, confidential, with redirect URI `https://bao.secforge.local/ui/vault/auth/oidc/oidc/callback` and similar for non-UI flows.

```
bao auth enable oidc
bao write auth/oidc/config \
  oidc_discovery_url="https://auth.secforge.local/realms/platform" \
  oidc_client_id="openbao" \
  oidc_client_secret="<from-keycloak>" \
  default_role="reader"
```

Map Keycloak realm roles to OpenBao policies via roles config.

## Phase 5.5 — Define policies

Create:

`admin.hcl` — full access (only mapped to my user via Keycloak `platform_admin` role)

`reader.hcl`:
```
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
```

`helloworld-bff.hcl` (for Phase 9):
```
path "secret/data/apps/helloworld/+" {
  capabilities = ["read"]
}
path "database/creds/helloworld-app-readwrite" {
  capabilities = ["read"]
}
```

Document each in docs/06-reference/openbao-policies.md.

## Phase 5.6 — Revoke initial root tokens

After OIDC works (verify by logging into the Web UI as your Keycloak passkey user):
```
bao token revoke <initial-root-token>  # for the main openbao
```

The seal-openbao keeps its root for break-glass, but is locked down to only your laptop NetworkPolicy.

## Phase 5.7 — Secrets engines

```
bao secrets enable -version=2 -path=secret kv
bao secrets enable database
bao secrets enable transit
```

### Configure dynamic Postgres credentials for `secforge-app-db`:

```
bao write database/config/secforge-app \
  plugin_name=postgresql-database-plugin \
  allowed_roles="helloworld-app-readwrite,helloworld-app-readonly" \
  connection_url="postgresql://{{username}}:{{password}}@<postgres-svc>:5432/postgres?sslmode=require" \
  username="<bootstrap>" \
  password="<initial>"

# Rotate immediately so OpenBao owns the creds
bao write -force database/rotate-root/secforge-app

# Define the role
bao write database/roles/helloworld-app-readwrite \
  db_name=secforge-app \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```

### Configure Transit for app-level encryption:
```
bao write -f transit/keys/pii-encryption type=aes256-gcm96
```

## Phase 5.8 — SPIRE → OpenBao integration

We documented this pattern in Phase 2. Implement now:
- Enable JWT auth in OpenBao:
  ```
  bao auth enable jwt
  bao write auth/jwt/config \
    jwks_url="http://spire-server.spire.svc.cluster.local:8443/keys" \
    bound_issuer="https://spire-server.spire.svc.cluster.local"
  ```
- Create a role binding that maps SPIFFE IDs to policies:
  ```
  bao write auth/jwt/role/helloworld-bff \
    role_type=jwt \
    bound_audiences=openbao \
    bound_subject="spiffe://secforge.local/ns/app/sa/helloworld-bff" \
    user_claim=sub \
    policies=helloworld-bff \
    ttl=1h
  ```

Workloads now: fetch JWT-SVID from SPIRE (audience = "openbao"), POST to OpenBao auth/jwt/login, get back a token bound to the role.

This is the local equivalent of cloud IAM federation.

## Phase 5.9 — Test workload auth

Deploy a test pod that exercises the SPIRE → OpenBao flow. Verify it can read a secret and obtain a dynamic Postgres credential.

## Phase 5.10 — Migrate Phase 1-4 secrets to OpenBao

Anything stored as a K8s Secret that's not a TLS keypair (those stay) — migrate:
- SpiceDB pre-shared key → secret/spicedb/preshared-key
- Keycloak client signing keys → secret/keycloak/clients/<name>
- Other passwords currently in K8s Secrets

Use OpenBao Agent or Vault Secrets Operator to make these available to pods that need them.

## Phase 5.11 — Audit logging

```
bao audit enable file file_path=stdout
```

## Phase 5.12 — Documentation

Update:
- docs/01-architecture/05-secrets-management.md
- docs/03-runbooks/openbao-recovery.md
- docs/03-runbooks/openbao-seal-unseal.md (when Docker Desktop restarts, the seal-openbao re-seals — here's how to unseal it)
- docs/06-reference/openbao-policies.md
- docs/02-decisions/0005-openbao-seal-strategy.md

## Constraints

- Auto-unseal via Transit (production pattern), not dev mode
- Initial root tokens revoked once OIDC works
- Audit logging enabled before sensitive operations
- All policies follow least-privilege; no broad `*` paths except `admin`
- Database creds are short-lived (default 1h, max 24h)
- Workload auth via SPIFFE-bound JWT, not static tokens
```

---

## Success criteria

- [ ] openbao-seal deployed and unsealed
- [ ] Main openbao deployed, auto-unseals via Transit
- [ ] Recovery keys safely offline
- [ ] Kubernetes auth, OIDC auth, JWT (SPIRE) auth all configured
- [ ] Initial root tokens revoked
- [ ] Test workload fetches a dynamic Postgres credential
- [ ] Audit logging produces structured JSON
- [ ] Phase 1-4 secrets migrated to OpenBao
- [ ] Documentation updated; PLAN.md updated

---

## Troubleshooting

### "Main openbao won't unseal — Transit error"
The seal-openbao might be sealed itself (Docker Desktop restarted). `bao status` on the seal-openbao first; if sealed, unseal it with the Shamir keys you stored offline. Then the main openbao auto-unseals.

### "OIDC login fails — invalid client"
Check the redirect URI exactly matches between Keycloak and OpenBao config.

### "Test pod can't authenticate via JWT"
SPIRE's JWKS endpoint must be reachable from OpenBao pods. Check NetworkPolicy. JWT-SVID's audience must match `bound_audiences`.

---

## What's next

[Phase 6 — Service Mesh + BFF](./phase-06-istio-bff.md).
