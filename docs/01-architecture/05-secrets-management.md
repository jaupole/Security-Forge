# Secrets Management (OpenBao)

> **Production note.** Written for the local edition; the Transit auto-unseal model below is unchanged in production (OpenBao 2.5.4, 3 nodes + 1 seal node). Substrate deltas: a "Docker Desktop restart" maps to a **node reboot**; ingress is the **Istio gateway**; OpenBao is reached at **`bao.secforge.dev` (tailnet-only)**; TLS is **Let's Encrypt**; the SPIRE trust domain is **`secforge.platform`**. See [PLAN.md](../../PLAN.md) and [00-overview.md](./00-overview.md).

> Companion ADRs:
> - [ADR-0009 — OpenBao seal strategy (two-instance Transit auto-unseal)](../02-decisions/0009-openbao-seal-strategy.md)
> - [ADR-0001 — Local-first build](../02-decisions/0001-local-first.md)
>
> Runbooks:
> - [openbao-seal-unseal.md](../03-runbooks/openbao-seal-unseal.md) — manual unseal after Docker Desktop restart
> - [openbao-recovery.md](../03-runbooks/openbao-recovery.md) — recovery-key procedure, root regeneration
>
> Policies: [docs/06-reference/openbao-policies.md](../06-reference/openbao-policies.md)

This document describes how the platform manages secrets — credentials, signing keys, encryption keys, dynamic database credentials — through OpenBao. The deployment uses the production-realistic Transit auto-unseal pattern (two cooperating OpenBao instances), not OpenBao dev mode. The trade-off is more setup and a manual step after every Docker Desktop restart; the win is the operational muscle memory transfers to cloud unchanged.

---

## Goals

1. **No long-lived database credentials anywhere.** Apps fetch short-lived (1h default, 24h max) Postgres credentials from OpenBao at startup; rotation is automatic on TTL expiry.
2. **No static API tokens between services.** Workloads authenticate to OpenBao with their SPIFFE ID (JWT-SVID issued by SPIRE); OpenBao issues a per-workload token bound to a least-privilege policy.
3. **Application-level encryption-as-a-service.** Apps encrypt PII through OpenBao's Transit engine without ever holding the key — same pattern locally and in cloud.
4. **Auditable.** Every secret read, every credential issuance, every policy change is logged in structured JSON and stream-routed to STDOUT (Phase 7 picks up Loki/Wazuh).
5. **Production seal pattern locally.** Auto-unseal via Transit, not Shamir-on-startup-prompt.

---

## Topology — two cooperating instances

The cloud-edition pattern is "main OpenBao auto-unseals via cloud KMS." Locally we have no KMS, so we build a tiny Transit-only OpenBao to play that role:

```
                ┌─────────────────────────┐
                │     openbao-seal        │     a tiny "KMS"
                │   (1 replica, file      │     - Transit engine only
                │    storage on PVC,      │     - sealed by Shamir 5-of-3
                │    Shamir-sealed)       │     - manually unsealed on each
                └────────────┬────────────┘       Docker Desktop restart
                             │ Transit
                             ↓ encrypt/decrypt
                ┌─────────────────────────┐
                │       openbao           │     the platform's OpenBao
                │   (3 replicas, Raft     │     - all platform secrets
                │    storage,             │     - auto-unseals via the
                │    Transit auto-unseal) │       seal-OpenBao Transit key
                │                         │     - Shamir is replaced by
                │                         │       recovery keys (5/3)
                └────────────┬────────────┘
                             │ HTTPS
                             ↓ (cert-manager-issued)
              ─────────────────────────────────
                 https://bao.secforge.dev
                 (Ingress, NetworkPolicy
                  source-restricted to laptop)
```

Two distinct trust roles:

- **`openbao-seal`** is the trusted root. Its compromise compromises the main OpenBao's seal key, which means anyone with the seal-OpenBao's data and Transit key can decrypt the main OpenBao's data at rest. We keep its blast radius minimal: it serves only the Transit engine, has only one client (the main OpenBao), is on its own NetworkPolicy that allows ingress only from the main OpenBao's pods, and its root token is the only one we keep around long-term (for break-glass recovery). It runs Shamir-sealed because there's nothing higher in the trust chain to auto-unseal it; the operator must unseal it manually (with 3 of 5 keys held offline) after every restart.
- **`openbao` (the main one)** holds the platform's actual secrets — KV-v2 paths, dynamic Postgres credentials, app-level encryption keys, auth-method state. It auto-unseals via Transit; recovery keys (also 5/3, also held offline) only matter for recovery operations (rebuilding the seal-OpenBao or regenerating the root). The initial root token is **revoked** as soon as OIDC auth is verified.

### Why two OpenBaos and not just dev mode

Dev mode runs a single OpenBao with an in-memory store, an automatically-unsealed instance, and a fixed root token. It's correct for "I'm experimenting with OpenBao for the first time." It's wrong for the platform because:
- Apps and operational scripts authored against dev-mode happily ignore unseal semantics; the production migration discovers a class of bugs in real-time.
- Storage is in-memory — a pod restart wipes all secrets, all auth-method config, everything.
- The root token never expires.

Building the two-instance Transit-auto-unseal pattern locally exercises every operational procedure that matters in cloud, with the same Helm values and the same `bao` commands. The only thing that changes at cloud migration is the **seal block** in the main OpenBao's config: `seal "transit"` → `seal "awskms"` (or `"gcpckms"`, etc.).

[ADR-0009](../02-decisions/0009-openbao-seal-strategy.md) records this decision.

### Cost — the manual unseal cadence

After Docker Desktop restarts, the seal-OpenBao re-seals (Shamir doesn't auto-unseal). The main OpenBao's auto-unseal path then fails because the seal-OpenBao's Transit endpoint isn't accepting requests. Operationally:

1. `bash infrastructure/openbao/unseal-seal.sh` — paste 3 of the 5 unseal keys (or pipe from a script you have).
2. Within ~10 seconds the main OpenBao auto-unseals.

Documented in `docs/03-runbooks/openbao-seal-unseal.md`. Acceptable for local; this is the only operational annoyance vs. cloud.

---

## Auth methods

The main OpenBao enables three auth methods, each with a distinct purpose:

| Method | Who | Token issuance | Use case |
|---|---|---|---|
| `kubernetes` | platform admin tooling running in the cluster | service-account token → OpenBao token | one-off operator scripts (kcadm-style runbook helpers) |
| `oidc` | humans (the project owner today, team members later) | Keycloak ID token → OpenBao token | Web UI access, breaking-glass via personal admin login |
| `jwt` | workloads (BFFs, apps) | SPIRE-issued JWT-SVID → OpenBao token | every app-to-OpenBao call. **Primary** auth path |

### Kubernetes auth

The auth method's `kubernetes_host` and `kubernetes_ca_cert` come from the standard in-cluster paths (`/var/run/secrets/kubernetes.io/serviceaccount/{ca.crt,token}`). Bound to ServiceAccount + namespace. Used sparingly — for jobs/runbooks where SPIRE-bound JWT isn't convenient.

### OIDC (Keycloak)

A confidential Keycloak client `openbao` lives in the **`platform`** realm (the staff realm), with redirect URIs:
- `https://bao.secforge.dev/ui/vault/auth/oidc/oidc/callback` — UI
- `https://bao.secforge.dev/oidc/callback` — CLI flow

Keycloak realm roles map to OpenBao policies via `auth/oidc/role/<keycloak-role>` bindings. The `platform_admin` realm role → OpenBao `admin` policy is the only mapping today.

### JWT (SPIRE)

The most-used path in the running platform. OpenBao validates JWT-SVIDs by fetching SPIRE's JWKS and checking issuer + audience + expiry. Each auth role binds a SPIFFE ID prefix to one or more OpenBao policies:

```
auth/jwt/role/helloworld-bff
  bound_audiences=openbao
  bound_subject=spiffe://secforge.platform/ns/app/sa/helloworld-bff
  user_claim=sub
  policies=helloworld-bff
  ttl=1h
```

Workloads:
1. Fetch JWT-SVID from the SPIFFE Workload API socket (mounted by SPIFFE-CSI), with `audience=openbao`.
2. POST to `https://openbao.openbao.svc:8200/v1/auth/jwt/login` with the JWT.
3. Get back a one-hour OpenBao token bound to the `helloworld-bff` policy.
4. Use that token to read secrets and fetch dynamic credentials.

Token expiry < SVID expiry, so even if a token is somehow leaked, it dies within an hour and re-issuance requires fresh SPIRE attestation.

---

## Secrets engines

| Path | Engine | Purpose |
|---|---|---|
| `secret/` | `kv-v2` | Static secrets — API keys, signing keys, OIDC client secrets |
| `database/` | `database` | Dynamic, short-lived Postgres credentials per role |
| `transit/` | `transit` | App-level encryption-as-a-service (PII fields, secrets-at-rest in app DBs) |

### `kv-v2` at `secret/`

KV-v2 has versioning + soft-delete + check-and-set semantics. Used for credentials we can't make dynamic:
- `secret/spicedb/preshared-key` — until SpiceDB supports dynamic auth (not on the roadmap)
- `secret/keycloak/clients/<client-id>/private-jwt` — BFF private keys for Keycloak `private_key_jwt`
- Future: `secret/apps/<app>/<env>/<key>` — per-app static config

Rotation is manual via `bao kv put` (creates a new version) + consumer pickup.

### `database/`

Configured against two CNPG clusters: `secforge-app` (Phase 1 cluster, helloworld backend) and `secforge-spicedb` (Phase 7d.2). On role-creation request, OpenBao opens a new SQL connection (using its own bootstrap creds), runs the `creation_statements` template (typically `CREATE ROLE ... WITH LOGIN PASSWORD '...' VALID UNTIL '...'; GRANT ...`), and returns the freshly minted username/password to the caller.

Roles defined today:
- `helloworld-app-readwrite` — TTL 1h, max 24h, full read/write on `secforge-app`'s public schema
- `helloworld-app-readonly` — TTL 1h, max 24h, read-only
- `spicedb-readwrite` — TTL 1h, max 24h, DML (SELECT/INSERT/UPDATE/DELETE) on `secforge-spicedb`'s public schema. Schema migrations during SpiceDB Operator upgrades require a temporary fallback to the static `spicedb` user (Postgres has no `GRANT ALTER`); see [`docs/03-runbooks/spicedb-operations.md` § SpiceDB schema migration during operator upgrades](../03-runbooks/spicedb-operations.md).

Phase 9 BFFs ask for `database/creds/helloworld-app-readwrite` at startup, get a username + password good for an hour, and either renew or re-fetch on expiry. No long-lived passwords ever.

SpiceDB consumes `database/creds/spicedb-readwrite` indirectly via the `spicedb-datastore-refresher` CronJob (Phase 7d.2 / [ADR-0023](../02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md)) — the CronJob mints a fresh credential every 12h and writes a new KV-v2 version at `secret/data/spicedb/config` (combined with the static PSK), VSO renders the rendered Secret, and SpiceDB Operator triggers a pod roll. The indirection is required because SpiceDB Operator's `secretName` semantics demand a single Secret holding both `preshared_key` and `datastore_uri`, and VSO can't compose a single rendered Secret from two OpenBao sources.

### `transit/`

Holds keys that never leave OpenBao:
- `pii-encryption` (aes256-gcm96) — apps encrypt/decrypt user PII through OpenBao's `transit/encrypt/pii-encryption` and `transit/decrypt/pii-encryption` endpoints
- `unseal` (aes256-gcm96) — the **seal-OpenBao**'s Transit key used for the main OpenBao's auto-unseal path. Only the seal-OpenBao has this; the main OpenBao has its own Transit engine with different keys

Apps don't store ciphertexts back through Transit; they store ciphertexts in their own database. The Transit engine is purely a stateless cryptographic operation server.

---

## Audit

Audit is **enabled before** any policy or secret is written to the main OpenBao — every operation from the first one onward goes through the audit pipeline. Single audit device:

```
bao audit enable file file_path=stdout
```

Stdout is collected by the cluster log stack (Phase 7 wires Loki + Wazuh). Audit log entries are deterministic JSON: every request, every response, the policy that authorized it, the source IP / SPIFFE ID, the time. Sensitive values are HMAC'd, not plain.

The seal-OpenBao audits to the same channel.

---

## Network and TLS posture

### TLS

OpenBao serves HTTPS on port 8200 with a cert from cert-manager (`mkcert-issuer`). Two separate certs, mounted at `/openbao/tls/{tls.crt,tls.key}`:

- `openbao-seal-tls` — DNS names: `openbao-seal`, `openbao-seal.openbao.svc`, `openbao-seal.openbao.svc.cluster.local`. Internal-only; the seal-OpenBao is never exposed via Ingress.
- `openbao-tls` — DNS names: same in-cluster shortcuts plus `bao.secforge.dev` for the public Ingress.

### Pod hardening

Same standard as the rest of the platform (PSS-restricted enforced):

- `runAsNonRoot: true`, `runAsUser: 100`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`
- `readOnlyRootFilesystem: true` (OpenBao writes to /openbao/data which is its PV; root FS is read-only)

### Workload identity

Both OpenBao instances get SPIFFE-CSI volumes mounted at `/spiffe-workload-api`. Their SPIFFE IDs:
- `spiffe://secforge.platform/ns/openbao/sa/openbao-seal`
- `spiffe://secforge.platform/ns/openbao/sa/openbao`

The seal-OpenBao doesn't actively use its SVID today; the main OpenBao uses its SVID for outbound calls to SPIRE (JWKS fetch for the JWT auth method) and Keycloak (OIDC discovery).

### NetworkPolicy

Default-deny ingress in `openbao` namespace; explicit allow rules:

- ingress-nginx → main openbao:8200 (UI/API public-ish access via Ingress with source-IP allowlist)
- main openbao → seal-OpenBao:8200 (for auto-unseal Transit calls)
- main openbao → Keycloak:8080 in `keycloak` ns (OIDC discovery)
- main openbao → SPIRE-server:8443 in `spire` ns (JWKS fetch for JWT auth)
- main openbao → Postgres in `app` ns (database secrets engine)
- main openbao → kube-apiserver (Kubernetes auth method's `kubernetes_host`)
- Pod-to-pod within the main openbao cluster (Raft on 8201)
- `observability` ns → metrics on 8200/sys/metrics
- DNS to kube-system

Egress is restricted on both pod sets to the listed destinations.

### Source-IP restriction on the public Ingress

`https://bao.secforge.dev` ingress carries `nginx.ingress.kubernetes.io/whitelist-source-range: "172.19.0.0/16,127.0.0.1/32"` — Docker Desktop's bridge range plus loopback, same pattern as Phase 3.6's admin ingress. Cloud edition swaps for a bastion/VPN CIDR.

---

## Resource budget

| Workload | Replicas | Memory request | CPU request | Memory limit | CPU limit |
|---|---|---|---|---|---|
| openbao-seal | 1 | 128 Mi | 50 m | 256 Mi | 250 m |
| openbao (main) | 3 | 256 Mi each | 100 m each | 512 Mi each | 500 m each |
| **Total** | **4** | **896 Mi** | **350 m** | **1.78 Gi** | **1.75** |

Plus the existing `secforge-openbao-db` Postgres (idle but kept running until decommissioned — see "What changes" below).

The `openbao` namespace ResourceQuota is bumped from 2 CPU / 2 Gi to 4 CPU / 8 Gi limits, 15 pods (matching the Keycloak / SpiceDB pattern from Phases 3-4).

---

## What changes at cloud migration

Most of the topology stays identical; what changes is the seal block on the main OpenBao:

1. **Seal block**: `seal "transit"` (pointing at openbao-seal) → `seal "awskms"` (or `"gcpckms"`, `"azurekeyvault"`). Same OpenBao binary, same data on disk; the seal-OpenBao is decommissioned.
2. **Recovery keys**: regenerated against the new seal during cutover (the old recovery keys are tied to the old seal). Documented in the migration playbook.
3. **Postgres source for the database secrets engine**: in-cluster CNPG → managed Postgres (RDS / Cloud SQL).
4. **Replicas**: 3 → 5+ if the workload demands it; 3 is already production-grade for Raft.
5. **Audit destination**: STDOUT → STDOUT (unchanged) plus a managed log sink (CloudWatch / Stackdriver). Format is identical.
6. **Storage**: integrated Raft remains; PV class changes from `hostpath` to `gp3`/`pd-ssd`/etc.
7. **Ingress source allowlist**: `172.19.0.0/16` → bastion/VPN CIDR.

Application code (every BFF's `auth/jwt/login` flow + secrets fetch) does not change.

---

## What is *NOT* in this phase

- **No replication/DR** between OpenBao clusters. Single Raft cluster locally; cloud edition adds Performance Replication.
- **No HSM-backed Transit keys.** Software keys only. Cloud KMS at migration provides HSM backing.
- **Vault Secrets Operator (VSO) — added in Phase 6.10b**, see [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md). Asymmetric pattern: operator-shaped consumers (SpiceDB via authzed-operator, AuthZEN façade with `envFrom`/volume-mount style) get K8s Secrets rendered by VSO from OpenBao; first-class apps with code paths we control end-to-end (BFF, the three product apps) keep reading directly from OpenBao via SPIFFE-bound JWT, no K8s Secret intermediate. The decision criterion is "who controls the consumer's secret-loading code path," not "what kind of secret." Per-consumer-namespace SA + VaultAuth + OpenBao K8s auth role required (TokenRequest is namespace-scoped). Manifests live under `infrastructure/vault-secrets-operator/` (operator install) plus `infrastructure/spicedb/06-vso-binding.yaml` and `apps/authzen-facade/deploy/05-vso-binding.yaml` (per-consumer bindings). Lessons + open questions captured in ADR-0015.
- **No PKI engine.** SPIRE handles workload-identity certs; cert-manager handles ingress TLS. PKI in OpenBao would duplicate. If a future app needs a private CA, we add it then.
- **No rotation policy on the seal-OpenBao Transit `unseal` key.** Rotating it requires re-sealing the main OpenBao with the new key, which is a moderately involved operation. Documented in the recovery runbook; not a routine cadence.
