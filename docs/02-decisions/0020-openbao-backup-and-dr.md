# ADR-0020: OpenBao backup and disaster recovery

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

OpenBao holds every secret the platform issues: BFF `private_key_jwt` keys for OIDC client authentication, SpiceDB pre-shared keys, Wazuh credentials (post-7d), Phase 9+ third-party API keys, dynamic database passwords. **Losing OpenBao = losing the platform.** Recovering from a Postgres failure is one Restore. Recovering from an OpenBao failure without a backup means rotating every credential it ever issued, re-bootstrapping every workload's identity binding, and re-issuing every Keycloak client's RSA keypair.

[ADR-0009](./0009-openbao-seal-strategy.md) covers seal-key custody (Shamir-on-laptop, 3-of-5 threshold). [`docs/03-runbooks/openbao-recovery.md`](../03-runbooks/openbao-recovery.md) covers seal-key recovery + Transit-token rotation. **Neither covers backup-restore of the data plane** — the Raft storage that holds policies, auth methods, KV entries, and the cluster identity.

This ADR defines the backup cadence, retention, storage, and recovery procedure. The runbook (the actual Restore steps) is a follow-up; this ADR is the decision and the contract.

## Decision

### Backup cadence

**Local edition**: Raft snapshots every **6 h**, retained **30 days** on the host filesystem at `/data/backups/openbao/`. Triggered by a CronJob inside the `openbao` namespace using OpenBao's `bao operator raft snapshot save` against the active leader.

**Cloud edition**: hourly snapshots, retained 90 days, written to object storage (S3 / GCS) with bucket-level lifecycle. Cross-region replication for the most recent 30 days. The cloud cadence is referenced here for migration planning; not implemented locally.

### Snapshot storage

Snapshots are written to a hostPath volume (`/var/secforge-backups/openbao/` on the Docker Desktop VM, mapped through to the host's filesystem so a host-level rsync or copy can mirror them off the VM). Files are named `openbao-snapshot-<UTC-timestamp>.snap` and are owned by the OpenBao service account (UID 65532). The host operator is responsible for moving snapshots off the local laptop to durable storage on a cadence the operator chooses (laptop disk failure is in scope as a recovery scenario; a host-only backup is not enough).

Snapshot files are **not** encrypted-at-rest beyond the host's disk encryption. Reasoning:
- Snapshots already contain Raft data ENCRYPTED with the unseal-key-derived wrap key — losing the file alone does not leak secrets.
- An attacker with both the snapshot file and the seal-OpenBao Shamir keys (or its raft data) can decrypt; that's a compromise of the seal layer, not the snapshot layer. Adding a second encryption layer here doesn't change that threat model.

### Retention

- Local: 30 days, automatic deletion of files older than retention via the same CronJob.
- The CronJob runs immediately after the snapshot to remove anything older than 30 days and emits a log line for each deletion.
- The retention window is short enough that a misconfigured backup script doesn't fill the disk but long enough that a "we noticed last Tuesday's data was wrong" investigation has working material.

### Recovery key custody

Already covered by [ADR-0009](./0009-openbao-seal-strategy.md): Shamir 3-of-5 on-laptop offline. **The recovery keys are NOT in the snapshot.** Restore requires the Shamir threshold AND a working snapshot. Losing one without the other is unrecoverable.

The **main OpenBao recovery keys** (per `bao operator init`'s output during Phase 5.2) live in the same offline custody as the seal-OpenBao Shamir keys. They are the break-glass mechanism if the OIDC admin login path itself breaks (e.g., Keycloak loses its realm-signing key in an unrelated incident).

### Recovery procedure (high-level — full runbook deferred)

1. Stand up a fresh OpenBao cluster (helm install).
2. Unseal the new cluster (Shamir keys).
3. `bao operator raft snapshot restore /path/to/snapshot.snap`. **The snapshot's cluster identity replaces the new cluster's identity** — this is intended; the restored cluster is bit-for-bit the same as the source.
4. Re-attach SPIRE workload-identity bindings (the auth/jwt mount's role configurations are inside the snapshot; what is NOT inside is the SPIRE trust relationship, which is in the SPIRE server, not OpenBao). For a restore-into-the-same-SPIRE-cluster scenario this is automatic; for a restore-into-a-fresh-SPIRE-cluster scenario the operator re-runs `infrastructure/openbao/configure-auth-k8s-jwt.sh` AFTER re-establishing SPIRE.
5. Verify by exercising one app's bootstrap path end-to-end: `kubectl rollout restart -n app deploy/helloworld-bff`, then check the BFF's startup log for "oidc client ready".
6. Rotate any credentials that were active during the lost window (the snapshot is from $T$ but the cluster failed at $T + \Delta$; transactions in $\Delta$ are lost — assume any token, password, or key issued in $\Delta$ is also lost and rotate it on the issuer side).

### Recovery objectives

- **RTO (Recovery Time Objective)**: 1 hour. Restoring a Raft snapshot is fast (~minutes for a multi-GB snapshot); the time budget is dominated by helm install + cert-manager re-issuing the OpenBao TLS cert + workloads re-bootstrapping their tokens.
- **RPO (Recovery Point Objective)**: 6 hours locally (matching the snapshot cadence), 1 hour in cloud. RPO is data-loss-since-last-snapshot, not data-loss-during-recovery; new tokens issued in the loss window are dead even if the workload hasn't noticed yet.

## What this ADR does NOT do

- **Provide the runbook.** A full step-by-step Recovery runbook (`openbao-backup-restore.md`) is a Phase 5 follow-up — flagged in PLAN.md as opened by this fix package. The full runbook covers: snapshot verification (the integrity hash), corrupted-snapshot handling, partial-restore (Phase 9 wants only some KV entries from a stale snapshot), and the cross-region replication flow for cloud edition.
- **Cover the seal-OpenBao backup separately.** Seal-OpenBao state is small and can be reconstructed from the operator's offline Shamir keys via `bao operator init` against a fresh seal-OpenBao deployment + restore of `unseal-policy` + Transit token re-issuance. ADR-0009's recovery procedure applies. We don't snapshot seal-OpenBao because the restore is "stand up new + restore policy + mint new token" rather than "preserve historical state."
- **Specify the CronJob YAML.** Implementation lives in `infrastructure/openbao/02-snapshot-cronjob.yaml` (added by the follow-up) — this ADR is the contract; the manifest is the implementation.

## Cross-references

- [ADR-0009](./0009-openbao-seal-strategy.md) — seal strategy + Shamir custody
- [`docs/03-runbooks/openbao-seal-unseal.md`](../03-runbooks/openbao-seal-unseal.md) — routine unseal procedure (different from restore)
- [`docs/03-runbooks/openbao-recovery.md`](../03-runbooks/openbao-recovery.md) — Transit-token rotation + admin-token break-glass (different from data-plane restore)
- [Fix after 07 § F-ADR-11](../../Fix%20after%2007/00-audit-findings.md#f-adr-11--medium--missing-adr--openbao-backuprestoredr) — the audit finding this ADR closes

## Re-evaluation triggers

- Cloud-edition migration changes storage backend (object storage instead of hostPath) → supersede with cloud-edition specifics.
- Wazuh / Phase 9+ apps surface a regulatory RPO requirement tighter than 6 h (e.g., FedRAMP Moderate often expects 1 h) → tune snapshot cadence + supersede.
- An incident reveals snapshot integrity is unreliable in OpenBao 2.5.x specifically (e.g., Raft replays inconsistently after restore) → supersede with workaround AND a critical PLAN.md bullet to track upstream fix.
- The Phase 9 apps reach a data volume where 30-day retention exceeds reasonable disk usage → tune retention and supersede.

## Phase 5 follow-up opened by this ADR

`openbao-backup-restore.md` runbook + `infrastructure/openbao/02-snapshot-cronjob.yaml` implementation are both flagged for Phase 5 follow-up by this fix package. Tracked in PLAN.md (Fix-after-07 §D adds the line).
