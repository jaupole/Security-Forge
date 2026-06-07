# Runbook — Re-enable k3s Secrets-Encryption (and the reboot-storm gotcha)

> Closes operator-backlog **#79**. Background: the 2026-06-04 incident
> (`project_k3s_encryption_incident_2026_06_04`) left k3s secrets-encryption
> **disabled** with a **corrupt empty-key config baked into the datastore
> bootstrap**. This runbook is how that was cleanly re-enabled on 2026-06-05,
> what went wrong afterward (a SPIFFE-csi OOM cascade triggered by the restarts),
> and how to avoid it next time.

---

## 1. The root blocker (why a naive enable crash-loops)

On 2026-05-28 encryption was enabled **online** and the key was never persisted
by a clean restart, so the on-disk `encryption-config.json` AND the
**datastore bootstrap** (`/bootstrap/<hash>` in kine, field
`ControlRuntimeBootstrap.EncryptionConfig`) both ended up holding
`{"aescbc":{"keys":[]}}` (empty). On every start k3s reconciles the bootstrap
**datastore→disk** (since PR #4438 there is no 2-way sync — a newer on-disk
file is a *fatal* error, not a migration; `--cluster-reset` is the only
disk→datastore path and it is **etcd-only**, unsupported on sqlite/kine). So
flag-ON → apiserver reads empty keys → `aescbc.keys: Required value` →
crash-loop. **You must neutralize the datastore bootstrap copy; disk-only edits
cannot win.**

## 2. Procedure (offline clean-slate — let k3s mint a fresh key)

All mutation happens with **k3s stopped** behind a verified full backup. The
data plane (pods) keeps running across a k3s control-plane stop/restart.

```bash
# Phase 0 — backup + safety net
ssh secforge
sudo systemctl stop k3s
BK=/root/k3s-encrypt-enable-$(date +%Y%m%d-%H%M%S); sudo mkdir -p "$BK"
sudo cp -a /var/lib/rancher/k3s/server/db/state.db "$BK/"
sudo cp -a /var/lib/rancher/k3s/server/cred "$BK/cred"
sudo cp -a /etc/rancher/k3s/config.yaml "$BK/"
# integrity-gate the backup (python: PRAGMA integrity_check == ok) BEFORE proceeding

# Phase 1 — clean-slate the encryption state
#  a) move the stale on-disk files aside
sudo mv /var/lib/rancher/k3s/server/cred/encryption-config.json "$BK/disk-moved-aside/"
sudo mv /var/lib/rancher/k3s/server/cred/encryption-state.json  "$BK/disk-moved-aside/"
#  b) tombstone the bootstrap row so startup reconcile is a no-op.
#     key = /bootstrap/<sha256(token-password)[:12]>; python sqlite3:
#       UPDATE kine SET deleted=1 WHERE name='/bootstrap/<hash>' AND deleted=0;
#       then PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;
#  c) uncomment `secrets-encryption: true` in /etc/rancher/k3s/config.yaml
#  d) ⚠️ MIRROR the same edit into platform/host/k3s/config.yaml and commit.
#     That repo file is source-of-truth; 00-host-bootstrap.sh reinstalls it
#     and a host-only edit is silently reverted on its next run. Confirm
#     in-sync afterward: sudo platform/scripts/host-config-drift-check.sh

# Phase 2 — start: k3s sees flag ON + no config + no bootstrap → mints a fresh
#           AES-CBC key (new-cluster code path) and re-saves the bootstrap.
sudo systemctl start k3s

# Phase 3 — verify (GATE)
sudo k3s secrets-encrypt status            # Enabled, key aescbckey, "All hashes match"
#  probe: create a secret, read its raw kine value — must be prefixed
#         k8s:enc:aescbc:v1:aescbckey:   (proves at-rest encryption)

# Phase 4 — persistence test (THE step skipped on 2026-05-28)
sudo systemctl restart k3s                 # status must STILL be Enabled, same key
# (a full hardware reboot on 2026-06-05 validated this end-to-end — the key
#  survived a power-cycle.)

# Phase 5 — encrypt the pre-existing secrets at rest  (DONE 2026-06-05)
# ⚠️ `k3s secrets-encrypt reencrypt` is NOT an in-place encrypt — it errors
#    "incorrect stage: start" and only runs as the TAIL of a key rotation
#    (prepare → restart → rotate → restart → reencrypt = 2 k3s restarts =
#    the §3 mount-storm risk). To encrypt existing secrets WITHOUT a restart,
#    re-write them through the apiserver (the active provider encrypts on write):
sudo kubectl get secrets -A -o json | sudo kubectl replace -f -   # mutable secrets
#  → on 2026-06-05 this took 200 plaintext → 2, zero restarts. The 2 holdouts are
#    *immutable* (`kube-system/secforge-prod.node-password.k3s`,
#    `vault-secrets-operator/vso-cc-storage-hmac-key`) — apiserver replace can't
#    touch them; only the rotation-dance or delete/recreate can, deferred as low-value.
#    Verify at-rest: raw kine value of /registry/secrets/<ns>/<name> must start
#    `k8s:enc:aescbc:` (200 of 211 were bare `k8s\0` before this step).
```

Deriving the bootstrap key (read-only): `password` = the part after the first
`:` of `/var/lib/rancher/k3s/server/token` (after stripping the `K10…::`
prefix); key = `/bootstrap/` + `sha256(password)`hex`[:12]`.

## 3. ⚠️ The reboot-storm gotcha (what bit us, and the fix)

The procedure needs **≥3 k3s restarts in quick succession** (stop/start +
persistence-test restart). Each restart makes **every** SPIFFE-mounting pod
re-mount its `spiffe-workload-api` volume at once. That mount-storm, **stacked**
across rapid restarts, OOM-killed the **`spiffe-csi-driver`** at its 512Mi
limit → CSI socket broke → cluster-wide `MountVolume.SetUp failed` → pods
crash-looped → the single node **compute-starved** until even SSH was refused
(tailnet still ping-able; box just couldn't fork a shell). Recovery required a
**Hetzner hardware reset** (Robot → Reset → *Execute an automatic hardware
reset*; the kine sqlite is WAL/fsync crash-safe).

**Mitigations (do these):**
- **csi-driver memory is now 1Gi/256Mi** (`platform/values/spire.yaml`) — a fresh
  1Gi pod rode out the post-reboot mount-storm with 0 restarts. Keep it there.
- After any multi-restart k3s operation, **watch `spiffe-csi-driver` restarts**;
  if it climbs, `kubectl -n spire set resources ds/spire-spiffe-csi-driver -c
  spiffe-csi-driver --limits=memory=1Gi` immediately.
- Prefer to **space out** the restarts (let the mesh + csi settle between each).

## 4. Post-reboot recovery checklist (single-node)

> Codified: run `platform/scripts/openbao-unseal.sh` (step 2), then
> `platform/scripts/post-reboot-reconcile.sh` (steps 1,3,4,5 + a stale-CA scan +
> health summary; add `--reissue`/`--bounce` to act on findings). The manual
> steps below are what those scripts automate.

A power-cycle leaves these manual/transient steps — work them in order:

1. **csi-driver**: confirm the new pod is `2/2 Running` at 1Gi (apply the bump in
   the early-boot window if needed, before the storm peaks).
2. **openbao-seal**: comes up **Sealed** (Shamir) — operator unseals 3/5
   interactively (keys never on the CLI):
   `kubectl -n openbao exec -it openbao-seal-0 -c openbao -- sh` then
   `bao operator unseal -tls-skip-verify` ×3. Main tier auto-unseals via Transit.
3. **Istio ambient drift**: pods that restarted during CNI recovery lose their
   ztunnel HBONE path → DB/mTLS connections "terminate unexpectedly" (e.g.
   `control` crash-loops on its FORCE-RLS DB assertion). Fix:
   `kubectl -n istio-system rollout restart ds/istio-cni-node` then `ds/ztunnel`,
   then bounce the affected workload pods.
4. **stale node-lost pods**: force-delete any stuck `Unknown` pods
   (`--force --grace-period=0`); DaemonSet/Job controllers recreate them.
5. **stale failed Jobs**: delete CronJob Job objects that failed during the
   outage window so `KubeJobFailed` clears (newer runs already succeed).

## 5. Rollback (to known-good = encryption OFF)

`systemctl stop k3s` → restore `state.db` + the two `cred/encryption-*.json`
from the Phase-0 backup → re-comment the flag → `systemctl start k3s`. This is
bit-identical to the pre-#79 state and was the proven safety net throughout.

## Cross-refs
- Incident: memory `project_k3s_encryption_incident_2026_06_04`
- Encryption architecture: `project_encryption_architecture`, ADR on etcd-at-rest
- OpenBao unseal: [openbao-seal-unseal.md](./openbao-seal-unseal.md)
- csi-driver sizing: `platform/values/spire.yaml` (spiffe-csi-driver block)
