# Platform audit anchor — activation runbook (operator-backlog #85 / X-R1)

Tamper-evident anchoring of the **OpenBao audit log** — the platform counterpart
of the app-level anchors (`audit-anchors.md`). This runbook covers the one-time,
operator-gated steps to bring it live; the build (manifests, component wiring) is
already committed.

## What it does

OpenBao writes a `file` audit device to `/openbao/audit/audit.log` (a dedicated
PVC, HMAC'd — who/what/when, **not** secret values). A daily CronJob
(`platform/manifests/openbao/12-platform-audit-anchor.yaml`) reads the new byte
segment since the last anchored offset, sha256-chains it, signs the chain head
via `transit/sign/audit-signing` (Ed25519, `deletion_allowed=false`), and commits
a signed anchor to the off-node public repo `jaupole/secforge-audit-anchors` under
`platform/openbao/`. An hourly verifier (`13-...`) re-reads the anchored ranges
from the local file and **fails the Job** on any mismatch → `PlatformAuditVerifierFailing`
(critical). Even if node-root later rewrites the local file, the Transit signature
already committed off-node won't match → tamper is provable (threat-model X-R1/P1).

Reuses the existing `transit/keys/audit-signing` key + `audit-signer` policy +
`platform-audit-signer` k8s-auth role (05c/05j) and the member-hub VSO-PAT pattern.

## Why it ships suspended + operator-gated

Three reasons the CronJobs ship `suspend: true` and this is not auto-applied:

1. **Root token.** Enabling the audit device, the role, and writing the PAT all
   need OpenBao admin (root token from 1Password via the `openbao-root-token-tmp`
   Secret — same gate as 05c/05j).
2. **The file audit device fails CLOSED.** Once enabled, if its PVC can't be
   written OpenBao **rejects all requests**. The dedicated `auditStorage` PVC +
   the `OpenBaoAuditVolumeFilling/Critical` alerts mitigate this, but first-enable
   is a deliberate moment.
3. **Existing clusters need a StatefulSet recreate** (see the gotcha below) — a
   sensitive operation on the crown-jewel component.

---

## A. Existing cluster (already deployed) — add the audit volume

> ⚠️ **Immutable `volumeClaimTemplates` gotcha.** `auditStorage.enabled: true`
> adds a new `volumeClaimTemplate` (`audit`) to the OpenBao StatefulSet.
> Kubernetes **forbids** modifying a StatefulSet's `volumeClaimTemplates` in
> place, so a plain `helm upgrade` will error
> (`updates to statefulset spec ... are forbidden`). Recreate the STS with
> `--cascade=orphan` (pods keep running + serving — OpenBao stays up), then roll
> pods one at a time so each mounts the new audit volume and auto-unseals.

```bash
# 0. Pull the committed change on the box.
cd ~/secforge && git pull --ff-only

# 1. Orphan the StatefulSet (the 3 pods keep running + serving; no outage).
sudo -n kubectl -n openbao delete statefulset openbao --cascade=orphan

# 2. Recreate the STS with the audit volumeClaimTemplate (adopts the orphaned
#    pods by label; creates audit-openbao-{0,1,2} PVCs). Idempotent re-run of 05b
#    does exactly this helm upgrade (it skips the irreversible init — already
#    initialized) — OR run helm directly:
helm upgrade openbao openbao/openbao -n openbao \
  --version 0.27.2 -f ~/secforge/platform/values/openbao.yaml

# 3. Roll pods ONE AT A TIME, standbys first, leader (openbao-0) LAST. Each new
#    pod mounts /openbao/audit and auto-unseals via Transit. Wait Ready+unsealed
#    between each (quorum preserved).
for p in openbao-2 openbao-1 openbao-0; do
  sudo -n kubectl -n openbao delete pod "$p"
  # wait until Ready and sealed=false before the next:
  sudo -n kubectl -n openbao rollout status pod/"$p" --timeout=180s || true
  sudo -n kubectl exec -n openbao "$p" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json | grep '"sealed"'
done

# 4. Confirm the audit PVC is bound and mounted.
sudo -n kubectl -n openbao get pvc | grep audit-openbao-0
```

On a **fresh build** none of section A applies — `05b` installs OpenBao with
`auditStorage` from the start. Skip to section B.

---

## B. Enable the audit device + role + manifests (root token)

```bash
# 1. Provide the root token (paste from 1Password; never echoes).
sudo -n kubectl create secret generic openbao-root-token-tmp -n openbao \
  --from-literal=token=<paste-root-token>

# 2. 05c enables the `file` audit device at /openbao/audit/audit.log (mode 0644,
#    so the anchor's non-root uid can read it) + loads the platform-audit policy.
#    Idempotent.
bash ~/secforge/platform/components/05c-openbao-configure.sh

# 3. Confirm the device is active AND OpenBao still serves (it fails closed —
#    verify before trusting it).
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- \
  env BAO_SKIP_VERIFY=1 bao audit list
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- \
  env BAO_SKIP_VERIFY=1 bao kv get secret/platform   # any read = still serving

# 4. 05j upserts the platform-audit-signer role AND applies the (suspended)
#    anchor + verifier manifests.
bash ~/secforge/platform/components/05j-app-vso-roles.sh
```

## C. Provision the GitHub PAT

The anchor pushes to `jaupole/secforge-audit-anchors`. **Reuse the existing
fine-grained PAT** ("SecForge Audit Anchors", Contents:RW on that repo, expires
2027-05-19 — already minted for member-hub, see `audit-anchors.md`) or mint a new
one scoped identically. Write it to OpenBao at the **platform** path:

```bash
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- \
  env BAO_SKIP_VERIFY=1 BAO_TOKEN=<root-token> \
  bao kv put secret/platform/audit-anchors-push-token token=<paste-PAT>

# VSO renders it into the audit-anchors-push-token Secret in the openbao ns
# (VaultStaticSecret in 12-...). Confirm it materialised:
sudo -n kubectl -n openbao get secret audit-anchors-push-token
```

> The verifier needs **no** PAT — it reads the public anchors unauthenticated from
> `raw.githubusercontent.com` and holds zero credentials.

## D. Delete the root token, then activate

```bash
sudo -n kubectl delete secret -n openbao openbao-root-token-tmp

# Unsuspend the CronJobs.
sudo -n kubectl -n openbao patch cronjob platform-audit-anchor   -p '{"spec":{"suspend":false}}'
sudo -n kubectl -n openbao patch cronjob platform-audit-verifier -p '{"spec":{"suspend":false}}'
```

## E. Verify end-to-end

```bash
# 1. Anchor test run — should read the file, sign via Transit, and commit
#    platform/openbao/<date>.json + _state.json to secforge-audit-anchors.
sudo -n kubectl -n openbao create job --from=cronjob/platform-audit-anchor anchor-test
sudo -n kubectl -n openbao logs job/anchor-test -f
#   expect: "anchored <N> bytes [0..<M>], <L> lines, full_hash=... -> platform/openbao/<date>.json"

# 2. Confirm the commit landed (public repo).
#    https://github.com/jaupole/secforge-audit-anchors/tree/main/platform/openbao

# 3. Verifier on the clean chain → exit 0.
sudo -n kubectl -n openbao create job --from=cronjob/platform-audit-verifier verify-test
sudo -n kubectl -n openbao logs job/verify-test
#   expect: "platform-audit chain intact: 1 anchor(s), 1 range(s) re-read, ..."

# 4. Clean up test jobs.
sudo -n kubectl -n openbao delete job anchor-test verify-test
```

**Tamper drill (optional, off-box):** clone the anchors repo + a copy of the
audit file, hand-edit a byte inside an anchored range, point a local run of
`verify.py` at the copy → it exits 1 with `TAMPER: segment hash mismatch`. Do
**not** edit the live audit file — that would (correctly) trip the real alert.

## Operational notes / follow-ups (operator-backlog #85)

- **Log rotation.** The anchor tracks a byte offset and does not rotate the file;
  it grows on the 2Gi `auditStorage` PVC. `OpenBaoAuditVolumeFilling` (75%) /
  `Critical` (90%) alert before the fail-closed wall. Automated rotation
  (`mv` + OpenBao audit reload to reopen the path, re-baseline the offset) is the
  fast follow-up.
- **Leader failover.** OpenBao audits on the **active** node (normally
  `openbao-0`). The MVP anchors `audit-openbao-0`. If leadership moves, that
  file stops growing and a standby's grows — multi-node coverage (anchor all
  three, or detect the leader) is a tracked follow-up.
- **Phase 2.** A broad Loki anchor over the security-critical namespaces is the
  deferred Phase 2 (content-based, retention/compaction-tolerant).

## References

- `platform/manifests/openbao/12-platform-audit-anchor.yaml` (anchor + NPs + VSO PAT)
- `platform/manifests/openbao/13-platform-audit-verifier.yaml` (verifier)
- `platform/components/05c-openbao-configure.sh` (audit device + policy)
- `platform/components/05j-app-vso-roles.sh` (role + manifest apply)
- `platform/values/openbao.yaml` (`auditStorage`)
- `platform/manifests/observability/09-platform-alerts.yaml` (`platform-audit-anchoring` group)
- `docs/03-runbooks/audit-anchors.md` (the app-level sibling)
- `docs/04-security/threat-model.md` §0.5 (X-R1 detective gap)
- <https://github.com/jaupole/secforge-audit-anchors>
