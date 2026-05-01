# ADR-0009: OpenBao Seal Strategy — Two-Instance Transit Auto-Unseal (Local Edition)

**Status**: Accepted
**Date**: 2026-04-29
**Decision-makers**: Project owner

## Context

OpenBao stores its data on disk in encrypted form. The decryption key is "the seal key." On every pod start, OpenBao must unseal — i.e. obtain the seal key and decrypt its in-memory state — before serving any request. The seal mechanism is one of:

- **Shamir** — the seal key is split into N shares; M of N must be presented (typically by humans) to unseal. Default; secure but operationally painful (every restart prompts for keys).
- **Transit auto-unseal** — the seal key is wrapped with a key held in another OpenBao's Transit engine. The wrapped key is stored in the local OpenBao's storage; on startup, the local OpenBao decrypts it via the upstream Transit endpoint. No human prompt.
- **Cloud KMS auto-unseal** — same pattern, but the unseal key is in a cloud KMS (AWS KMS / GCP KMS / Azure Key Vault).
- **Dev mode** — no seal; everything is in-memory; root token printed on stdout. Single-process testing only.

The cloud edition uses cloud KMS auto-unseal. Locally there is no cloud KMS. We need a story that:

1. Is operationally similar to cloud (same auto-unseal path, same OpenBao config shape) so apps and runbooks transfer unchanged.
2. Is acceptable for local development without recreating cloud infrastructure.
3. Doesn't introduce a single dev-mode vs. production-mode codepath divergence.

## Decision

**Run two OpenBao instances locally:**

1. **`openbao-seal`** — a tiny OpenBao that runs *only* the Transit secrets engine. Sealed by Shamir (5-of-3). The only client of its Transit endpoint is the main OpenBao. It is unsealed manually by the operator after every Docker Desktop restart, using 3 of 5 unseal keys held offline.
2. **`openbao` (main)** — the platform's OpenBao. 3 replicas, integrated Raft storage. Configured with `seal "transit" { address = "http://openbao-seal..." token = ... key_name = "unseal" mount_path = "transit/" }`. Auto-unseals on startup as long as `openbao-seal` is up and unsealed. Recovery keys (also 5-of-3) replace the Shamir keys for break-glass; the initial root token is revoked as soon as OIDC auth is verified.

We do not use OpenBao dev mode, and we do not use Shamir on the main OpenBao.

[Architecture: docs/01-architecture/05-secrets-management.md](../01-architecture/05-secrets-management.md)

## Rationale

### Why not dev mode

Dev mode is convenient and useless. It diverges from the production deployment in:

- **Storage**: in-memory; pod restart wipes everything.
- **Seal**: none; the root token is printed on stdout.
- **Auth methods**: the dev-mode token is unbounded; no OIDC, no JWT, no Kubernetes auth needs to be exercised.
- **Audit**: typically not enabled by default; we'd have to remember to enable it.

Apps and runbooks written against dev mode silently work-but-wouldn't-in-production. The cost of that divergence is paid at cutover, in the worst possible context (real users, real data). The two-instance pattern catches the same class of issues at this Phase, where blast radius is one developer.

### Why not just Shamir on the main OpenBao

Shamir works. Operationally, it means every Docker Desktop restart pauses platform availability until the operator enters keys. With 3 OpenBao replicas in a Raft cluster, the operator would unseal each replica individually — 3 keys × 3 replicas = 9 prompts per restart. With auto-unseal, the operator unseals the *seal*-OpenBao once (3 keys); the main OpenBao's three replicas come up automatically.

More importantly, Shamir-on-main means every BFF / app starting up in the cluster fails until the operator gets to the keyboard. Auto-unseal means the only thing that requires manual intervention is the seal-OpenBao itself, which has no app-side dependency.

### Why two OpenBaos and not one OpenBao with a file-key seal

The "file-key seal" alternative would be: keep the seal key in a Kubernetes Secret, mount it into the main OpenBao, point `seal` at it. This is similar to what `disk` plugins do for SPIRE.

Rejected because:
- The cloud-edition seal is `awskms` (or equivalent). Replacing `awskms` with `transit` at migration is a one-line config change. Replacing `file-key` with `awskms` is a more invasive change involving adopting an entirely different seal mechanism.
- A K8s Secret-backed file-key seal sits at the same trust level as the OpenBao itself — anyone with cluster admin can read both the Secret and the encrypted OpenBao data, and they're now able to decrypt. The seal-OpenBao adds one logical layer: even if the main OpenBao's data is exfiltrated, the attacker still needs to get past the seal-OpenBao's RBAC and Shamir.
- The operational procedure (manual unseal of the seal-OpenBao after restart) is itself a useful lesson in the seal-trust hierarchy that cloud KMS hides under cloud-IAM RBAC.

### Why exactly 5-of-3

OpenBao defaults to 5-of-3 (5 key shares, 3 needed to unseal). Other ratios are possible:

- **3-of-2** — fewer pieces of paper to manage; less resilience to a lost share.
- **7-of-4** — more shares to distribute across team members in a cloud setup.

For a single developer locally, 5-of-3 is the minimum reasonable resilience. If three of the five shares are stored across {1Password, paper in fireproof box, encrypted USB drive, encrypted backup, password manager backup}, any two losses still allow recovery. Going to 3-of-2 means a single lost share + a single forgotten share = total loss.

### Why we revoke the initial root token of the main OpenBao

The initial root token has unbounded power. While it's alive, anyone who reads it can perform any operation. Revoking it as soon as OIDC auth is verified means:

- Every subsequent admin operation is attributable to a Keycloak-authenticated human (audit trail).
- A leaked token from initial setup can't be used after revocation.
- The break-glass path becomes "regenerate a root token via the recovery keys" — a deliberate, audited operation that requires multiple recovery shares — instead of "the initial token is in $HISTORY/.bash_history."

The seal-OpenBao keeps its root for break-glass because it has no OIDC: it isn't worth wiring an OIDC client just for a once-a-month emergency operation. Its root is the only static credential we accept, and its blast radius is limited to NetworkPolicy-enforced in-cluster access from the main OpenBao plus operator port-forward.

## Alternatives considered and rejected

### Single-instance OpenBao with file-key seal

(See above.) Rejected because the cloud migration becomes more involved and the trust hierarchy collapses into one layer.

### Single-instance OpenBao with Shamir, manual unseal at every Docker Desktop restart

Operationally painful with 3 replicas (9 unseal prompts per restart). And the cloud migration removes Shamir entirely, so we'd be operating a config we never operate in cloud.

### Use Phase 1's `secforge-openbao-db` Postgres as the OpenBao storage backend

OpenBao supports Postgres as a storage backend, but it is **not** the recommended path: OpenBao team has been moving toward integrated Raft as the supported default for new deployments. Postgres-backed OpenBao loses the operational simplicity of self-contained Raft. Rejected; the `secforge-openbao-db` cluster will remain idle for the local edition (low cost, kept as an option for future use as an audit-log offload target). Decommissioning it is a one-command kubectl change once we're sure it's not needed.

### Run the seal-OpenBao on a different cluster / VM / host

Increases physical separation but Docker Desktop K8s is single-node anyway; physical separation is impossible without leaving the cluster entirely. The NetworkPolicy + namespace boundary is the practical isolation layer locally. Cloud KMS replaces it at migration.

## Consequences

### What this commits us to

- **Manual unseal procedure** after every Docker Desktop restart. Operator runs `bash infrastructure/openbao/unseal-seal.sh` and pastes 3 of 5 unseal keys. Documented in [docs/03-runbooks/openbao-seal-unseal.md](../03-runbooks/openbao-seal-unseal.md).
- **Five unseal keys + one initial root token + one Transit unseal-token** stored offline by the operator, never in any committed file or K8s Secret.
- **Five recovery keys + one initial root token** for the main OpenBao stored offline, used only for recovery / root regeneration.
- **OIDC auth must work before the initial root is revoked.** Hard ordering constraint in Phase 5 — the runbook makes this explicit.
- **Three Raft replicas locally** — single-node K8s, all 3 PVCs on the same disk. Raft consensus still works; physical fault tolerance does not. Acceptable for local; cloud spreads replicas across AZs.
- **Updates to OpenBao Helm chart are tested against the seal-OpenBao + main OpenBao pair**, not against a dev-mode instance.

### What this preserves

- Cloud migration is a one-line `seal` block change in the main OpenBao Helm values. Apps and policies are unchanged.
- The main OpenBao's data path (Raft → encrypted-at-rest with seal key → seal key wrapped by Transit) is identical between local and cloud; only the Transit upstream changes (seal-OpenBao locally, cloud KMS in cloud).
- The break-glass recovery procedure is the same in both environments: present recovery keys + Transit access (or KMS access) + use `bao operator generate-root` to mint a new root token.

### Known local gaps

1. **Single Raft cluster on a single node.** No machine-fault tolerance. Acceptable for local; documented gap.
2. **Seal-OpenBao on a single replica with file storage.** Loss of the seal-OpenBao's PVC means total loss of the main OpenBao's seal key (and therefore its data, even if recovery keys are present, because recovery keys don't decrypt the at-rest data — they only allow root regeneration on an unsealed OpenBao). Backup procedure for the seal-OpenBao's PV is in [docs/03-runbooks/openbao-recovery.md](../03-runbooks/openbao-recovery.md).
3. **No periodic rotation of the Transit unseal key on the seal-OpenBao.** Rotating it requires re-sealing the main OpenBao, which is invasive. Documented; not a routine cadence.

## Re-evaluation criteria

Re-open this ADR if:

1. The manual unseal cadence becomes onerous (e.g., the platform restarts often enough that the operator keeps the unseal keys in a less-secure location for convenience).
2. We move to a multi-node cluster locally (kind or Docker Desktop with multiple nodes), at which point we should reconsider whether the seal-OpenBao deserves its own node.
3. OpenBao adds a "self-seal" mechanism that's equivalent in security to the current two-instance pattern and simpler to operate.
4. Cloud migration is imminent — at which point we replace the seal block with the cloud KMS reference and decommission the seal-OpenBao.

## References

- [docs/01-architecture/05-secrets-management.md](../01-architecture/05-secrets-management.md)
- [docs/03-runbooks/openbao-seal-unseal.md](../03-runbooks/openbao-seal-unseal.md)
- [docs/03-runbooks/openbao-recovery.md](../03-runbooks/openbao-recovery.md)
- OpenBao Transit auto-unseal: <https://openbao.org/docs/configuration/seal/transit/>
- OpenBao integrated Raft: <https://openbao.org/docs/internals/integrated-storage/>
- Vault original auto-unseal RFC (OpenBao inherits): <https://developer.hashicorp.com/vault/docs/concepts/seal>
