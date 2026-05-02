# ADR-0015: Secret distribution pattern (VSO + direct-API)

**Status**: Accepted
**Date**: 2026-04-30
**Decision-makers**: Project owner

## Context

Phase 5.10 replicated SpiceDB's preshared key and four BFF `private_key_jwt`
keypairs into OpenBao but left the original Kubernetes Secrets in place as
the authoritative consumer source. Phase 6.10b finishes the migration so
OpenBao becomes the sole source of truth. The question this ADR answers:
**given that two distinct distribution patterns are viable (Vault Secrets
Operator rendering K8s Secrets vs. apps reading directly from OpenBao),
which workloads use which, and why?**

## Decision

Adopt an asymmetric pattern keyed on **who controls the consumer's
secret-loading code path**, not on what kind of secret is being distributed:

- **Operator-shaped consumption → Vault Secrets Operator (VSO).**
  Workloads whose secret-loading is controlled by an operator we don't
  own (SpiceDB via authzed-operator) OR by an envFrom/volumeMount-style
  pattern we deliberately keep simple (AuthZEN façade) get their secrets
  via VSO. VSO reads from OpenBao using K8s auth and renders K8s Secrets
  into the consumer's namespace.
- **First-class apps with code paths we control end-to-end → direct-API.**
  The BFF and the three product apps read secrets directly from OpenBao
  via `apps/lib/secrets/` using SPIFFE-bound JWT auth. No K8s Secret
  intermediate.

If a future workload we own ships a Helm chart whose consumer only knows
how to read K8s Secrets, it goes through VSO. If we control the code path,
it goes direct.

## What we built (Phase 6.10b implementation summary)

**VSO platform install** (Step 2):
- Vault Secrets Operator 1.3.0 installed in `vault-secrets-operator`
  namespace via the official `hashicorp/vault-secrets-operator` chart.
  Chart works against OpenBao 2.5.3 unchanged; the API surface VSO uses
  (`auth/kubernetes/login`, KV v2, `sys/health`) is identical to Vault.
- Cross-namespace `VaultConnection` `vault-secrets-operator/openbao`
  pointing at `https://openbao.openbao.svc.cluster.local:8200`. The
  mkcert CA bundle is copied from `cert-manager/mkcert-ca-key-pair`
  into a same-namespace `openbao-ca-bundle` Secret at apply time
  (no trust-manager — would have been a separate dependency).
- VSO uses K8s auth (not JWT/SPIRE) because VSO is platform-level and
  runs before SPIRE workload attestation can attach a SPIFFE-ID. JWT
  auth is reserved for application workloads.

**Per-consumer-namespace bindings** (Step 3):
- Each consumer namespace has its OWN ServiceAccount + VaultAuth +
  OpenBao K8s auth role. This is forced by VSO's design: it obtains
  the OpenBao login credential via TokenRequest against the consumer
  namespace's SA, and TokenRequest is namespace-scoped. Centralizing
  on a single operator SA is not possible.
- Concretely: `spicedb/spicedb-vso` SA → `auth/kubernetes/role/spicedb-vso`
  → `vso` policy; `app/authzen-facade-vso` SA →
  `auth/kubernetes/role/authzen-facade-vso` → `vso` policy.

**Two-path OpenBao layout for defense in depth**:
- `secret/data/spicedb/preshared-key` — PSK only. Read by AuthZEN's role.
- `secret/data/spicedb/config` — PSK + `datastore_uri`. Read by SpiceDB's
  role (the only consumer that needs the Postgres password).
- `secret/data/keycloak/clients/<id>` — BFF `private_key_jwt` keypairs,
  read direct-API via SPIFFE-bound JWT auth (no VSO involvement).

The `vso` policy whitelists the two `secret/data/spicedb/*` paths and
the `secret/data/keycloak/clients/+` glob (the latter listed defensively
per the migration story open question; not actually rendered today).

**`ca.crt` separation**: the AuthZEN façade originally bundled the
mkcert CA cert into the same K8s Secret as the PSK. Step 3 moved it to
a `spicedb-ca-bundle` ConfigMap (CA certs are public, don't belong in
Secrets). AuthZEN's pod now uses a `projected` volume combining the
VSO-rendered Secret + ConfigMap at the same `/etc/spicedb` mount.

**VaultStaticSecret refresh interval**: VSO default of 60s used for both
`spicedb-config-vso` and `authzen-facade-spicedb-creds-vso`. No tighter
cadence needed for the static keys we're rendering today; revisit if
rotation work in Phase 7 demands it.

## What we did NOT do

- **AuthZEN migration to direct-API**: deferred. AuthZEN remains
  operator-shaped (envFrom/volumeMount consumer) under the VSO path.
  Migration to `apps/lib/secrets/` is feasible but adds ~half day of
  work and is not required by anything in flight; revisit if AuthZEN
  ever needs dynamic secret rotation faster than VSO can render.
- ~~**OpenBao database secrets engine for SpiceDB**~~: ✅ **Resolved Phase 7d.2 (2026-05-02)**, with one structural caveat that drove a follow-on ADR. The original plan was to replace the `VaultStaticSecret` with a `VaultDynamicSecret` rendering credentials from a SpiceDB-specific database role. That ran into a VSO-inherent gap: SpiceDB Operator's `secretName` semantics require a single Secret holding **both** `preshared_key` and `datastore_uri`, and VSO can't compose a single rendered Secret from two OpenBao sources (one static KV, one dynamic engine). Phase 7d.2 ships the dynamic-cred role + a 12h CronJob that re-populates the existing static KV path from the database engine, leaving the VSO binding unchanged. Net effect: the original "CNPG password rotation desyncs the value" caveat is closed at the consumer level — SpiceDB sees a Secret that is never older than the dynamic-cred max_ttl. See [ADR-0023](./0023-spicedb-datastore-uri-rotation-pattern.md) for the full reasoning, the three approaches considered, and the cloud-edition revisit clause.
- **CLI redirect URI for OpenBao OIDC `admin` role**: surfaced during
  Step 2 when `bao login -method=oidc` failed because
  `http://localhost:8250/oidc/callback` is not in the role's
  `allowed_redirect_uris`. Worked around by getting tokens via the UI.
  Tracked as PLAN.md Phase 5 follow-up #3 (Phase 7 work).
- **Cosign signing for VSO operator images**: deferred per the existing
  Phase 6.7 follow-up posture (`verify-image-signatures` policy in Audit
  mode, ADR-0004). Cosign verification surfaces as warnings, not blocks.

## Lessons learned (carry forward)

1. **VSO + restricted PSS**. The chart's defaults set only `runAsNonRoot`
   + `allowPrivilegeEscalation: false`. The
   `pod-security.kubernetes.io/enforce: restricted` namespace label
   additionally requires `capabilities.drop=["ALL"]` and
   `seccompProfile.type=RuntimeDefault`. Override via the Helm values
   `controller.podSecurityContext` and `controller.securityContext`. A
   chart map override replaces the default wholesale, so the original
   keys must be re-stated. See `infrastructure/vault-secrets-operator/01-helm-values.yaml`.

2. **VSO K8s auth is namespace-scoped.** TokenRequest API is per-namespace,
   so the SA referenced by `VaultAuth.spec.kubernetes.serviceAccount`
   must live in the SAME namespace as the `VaultStaticSecret` that
   references it. Cross-namespace centralization is not possible. Each
   consumer namespace pays a per-ns boilerplate tax (SA + VaultAuth +
   OpenBao role).

3. **Stale Helm pre-delete hook on Kyverno-blocked installs.** If a
   Helm install fails partway through admission validation, Helm records
   the pre-fix template in its release history; the next `helm uninstall`
   re-runs that stale Job through Kyverno. Use `helm uninstall --no-hooks`
   to escape.

4. **Backticks in shell strings are footguns.** Inside bash double-quoted
   args (e.g. `green "..."`) AND inside unquoted heredoc bodies (`<<EOF`),
   backticks trigger command substitution. Two scripts in this work
   shipped with this bug. Lesson: lint scripts before claiming ready,
   and prefer `'...'` or `$(...)` over backticks anywhere bash interprets.

## Open questions (carried forward, not blocking)

- **AuthZEN migration to direct-API.** See "What we did NOT do." Worth
  revisiting once we have a load profile for AuthZEN that demands
  faster rotation than VSO's 60s refresh.
- **Migration story when a "first-class app" ships as a Helm chart**
  with a consumer we don't control. Does it become operator-owned for
  secrets? Likely yes — the criterion is "do we control the code path,"
  not "do we own the source." Document this in the doc-update commit
  if/when it surfaces with a real workload.
- **Per-consumer-namespace auth binding tax — when does it become a
  problem?** With 2 consumer namespaces today (spicedb, app), the
  boilerplate is acceptable. Threshold to revisit: ">3 consumer
  namespaces with operator-shaped consumption" → re-evaluate the
  VSO/direct-API split or look into a multi-tenant VaultAuth pattern.

## Operational hand-offs to other phases

ADR-0015 is one piece of the broader secret-management story. Three
explicit hand-offs documented in PLAN.md follow-ups:

- **Phase 7 — BFF `private_key_jwt` rotation.** Phase 6.10b moved BFF
  private keys into OpenBao but did NOT implement rotation. Rotation
  requires a runbook (mint new keypair → register public key with
  Keycloak via `kcadm-admin` → versioned write to OpenBao → BFF picks
  up on restart → deregister old public key after grace), a 90-day
  cron, and Phase 7 observability. ~half day.
- **Phase 7 — OIDC CLI redirect URI gap.** Add
  `http://localhost:8250/oidc/callback` to the `admin` role's
  `allowed_redirect_uris` and the Keycloak `openbao` client's Valid
  Redirect URIs. ~30 min.
- **Phase 3 — `kcadm-admin` migration.** Phase 6.10b's
  `bootstrap-bff-clients.sh` carries the `kcadm --otp` bug from
  Phase 6b-0. The full migration to a dedicated `kcadm-admin` service
  account is a Phase 3 follow-up — NOT folded into 6.10b.
- **OpenBao audit log reuse (Phase 7 observability).** Both VSO-mediated
  and direct-API reads appear in OpenBao's audit log with their SPIFFE
  IDs. Phase 7 observability should treat the audit log as the single
  source of truth for "who read which secret when."

## References

- [ADR-0013 — Outbound secrets: no env vars](./0013-outbound-secrets-no-env.md)
- [ADR-0014 — API auth library design](./0014-api-auth-library-design.md)
- [Phase 6.10b prompt](../05-claude-code-prompts/phase-06.10b-vso-and-secret-cleanup.md)
- CLAUDE.md architecture stack table — "Outbound Secret Sync" row
- `infrastructure/openbao/policies/vso.hcl` — the policy
- `infrastructure/vault-secrets-operator/` — VSO platform install
- `infrastructure/spicedb/06-vso-binding.yaml` — spicedb-side binding
- `apps/authzen-facade/deploy/05-vso-binding.yaml` — app-side binding
