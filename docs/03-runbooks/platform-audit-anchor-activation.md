# Platform audit anchor — activation runbook (operator-backlog #85 / X-R1)

Tamper-evident anchoring of the **OpenBao audit log** — the platform counterpart
of the app-level anchors (`audit-anchors.md`). This runbook covers the one-time,
operator-gated steps to bring it live; the build (manifests, component wiring) is
already committed.

## What it does

Each OpenBao replica writes a `file` audit device to `/openbao/audit/audit.log` on
its own dedicated PVC (HMAC'd — who/what/when, **not** secret values). A daily
CronJob (`platform/manifests/openbao/12-platform-audit-anchor.yaml`) mounts **all
three** audit PVCs read-only and, per node, reads the new byte segment since that
node's last anchored offset, sha256-chains it, signs the chain head via
`transit/sign/audit-signing` (Ed25519, `deletion_allowed=false`), and commits a
signed anchor to the off-node public repo `jaupole/secforge-audit-anchors` under
`platform/openbao/<node>/`. An hourly verifier (`13-...`) re-reads each node's
anchored ranges from its local file and **fails the Job** on any mismatch →
`PlatformAuditVerifierFailing` (critical). Even if node-root later rewrites a local
file, the Transit signature already committed off-node won't match → tamper is
provable (threat-model X-R1/P1).

**Why all three nodes:** in OpenBao Raft HA only the **active** node processes (and
therefore audits) requests; leadership moves between `openbao-{0,1,2}` (it was on
`openbao-2`, not `-0`, when this was built). Anchoring all three independent per-node
chains captures the trail wherever leadership currently sits — no leader-detection
needed. Standby files that never grew simply have no anchors yet.

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
#    pods by label; creates audit-openbao-{0,1,2} PVCs, 10Gi each). Idempotent
#    re-run of 05b does exactly this helm upgrade (it skips the irreversible init
#    — already initialized) — OR run helm directly:
helm upgrade openbao openbao/openbao -n openbao \
  --version 0.27.2 -f ~/secforge/platform/values/openbao.yaml

# 3. Find the ACTIVE node (only it audits; roll it LAST so leadership is the last
#    thing disturbed). Standbys first.
for p in openbao-0 openbao-1 openbao-2; do
  printf "%s " "$p"; sudo -n kubectl -n openbao exec "$p" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json | grep -o '"is_self":[^,]*'
done
# Roll pods ONE AT A TIME, the active node LAST (order it accordingly). Each new
# pod mounts /openbao/audit, loads the declarative file/ audit device from the
# updated config, and auto-unseals via Transit; wait Ready+unsealed between each
# (quorum preserved). (The same values change carries both the auditStorage VCT
# AND the audit{path="file/"} stanza, so the roll enables the device too.)
for p in <standby> <standby> <active-last>; do
  sudo -n kubectl -n openbao delete pod "$p"
  sudo -n kubectl -n openbao rollout status pod/"$p" --timeout=180s || true
  sudo -n kubectl exec -n openbao "$p" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json | grep '"sealed"'
done

# 4. Confirm all three audit PVCs are bound (10Gi each).
sudo -n kubectl -n openbao get pvc | grep audit-openbao

# 5. The same commit relaxes VaultStaticSecret spec.refreshAfter 60s→1h (cuts audit
#    volume ~60×). VSO honours the new interval once the changed VaultStaticSecret
#    objects are re-applied — re-run their owning components (07b/07e/07f/09a/09b/…)
#    or `kubectl apply` the changed manifests/<ns>/*vso-binding*.yaml. (A
#    vso.hashicorp.com/force-sync annotation triggers a one-off sync but does NOT
#    change the interval — re-applying the spec is what matters.)
```

On a **fresh build** none of section A applies — `05b` installs OpenBao with
`auditStorage` from the start. Skip to section B.

---

## B. Load policies + role + manifests (break-glass admin — no root token needed)

> The `file/` audit device is **declarative** — it is declared in
> `values/openbao.yaml` (`audit { path = "file/" }`) and enabled when the pods load
> that config in section A. OpenBao 2.5.4 **rejects** API enable
> (`bao audit enable` → "use declarative, config-based audit device management
> instead"), so `05c` only *verifies* it; it does not enable it. The admin steps
> below (policy load, role, PAT) just need an `admin`-policy token — mint one via
> the existing `admin-break-glass` k8s-auth role instead of the 1Password root token:

```bash
# 1. Mint a 1h admin token in-cluster and stage it where 05c/05j expect it
#    (no root token / 1Password needed; printf %s avoids a trailing newline).
SA=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
T=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
      bao write -field=token auth/kubernetes/login role=admin-break-glass jwt="$SA")
printf %s "$T" | sudo -n kubectl -n openbao create secret generic openbao-root-token-tmp \
  --from-file=token=/dev/stdin

# 2. 05c loads policies (incl. platform-audit) + verifies the config-declared
#    file/ device is present. Idempotent.
bash ~/secforge/platform/components/05c-openbao-configure.sh

# 3. Confirm BOTH audit devices exist AND OpenBao still serves. (file/ coexists
#    with stdout/: a request is audited if ≥1 device records it, so a full audit
#    PVC does NOT take OpenBao down — stdout backstops it.)
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- \
  env BAO_SKIP_VERIFY=1 bao audit list          # expect stdout/ AND file/
sudo -n kubectl exec -n openbao openbao-0 -c openbao -- \
  env BAO_SKIP_VERIFY=1 bao status              # serving check

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
# 1. Anchor test run — anchors each node; the ACTIVE node's file has bytes (commits
#    platform/openbao/<node>/<date>.json + _state.json), standbys log "skip".
sudo -n kubectl -n openbao create job --from=cronjob/platform-audit-anchor anchor-test
sudo -n kubectl -n openbao logs job/anchor-test -f
#   expect e.g.: "openbao-2: anchored <N> bytes [0..<M>], <L> lines -> platform/openbao/openbao-2/<date>.json"
#                "openbao-0: no audit file yet (standby, never active) — skip"

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

## Volume + rotation

Measured **~160 MB/day** of OpenBao audit (mostly VSO secret-refresh reads). The
same commit relaxes VaultStaticSecret `refreshAfter` 60s→1h (step A.5), cutting that
~60× to roughly tens of MB/day. With the **10 Gi** `auditStorage` PVC that's many
months of runway; `OpenBaoAuditVolumeFilling` (75%) / `Critical` (90%) warn well
before the file device fails closed.

The anchor tracks a byte offset and does **not** rotate the file. When a node's PVC
approaches full (or annually), rotate **manually** at a maintenance window. The
device is config-declared, so rotation is `mv` + pod-roll (NOT `bao audit disable`,
which 2.5.4 rejects). Per node with a growing file:

```bash
# 1. Run one final anchor so the current tail is committed off-node.
sudo -n kubectl -n openbao create job --from=cronjob/platform-audit-anchor anchor-prerotate
# 2. Move the file aside, then delete the pod so it reloads config and reopens a
#    fresh /openbao/audit/audit.log. (stdout/ keeps auditing throughout, so there
#    is no audit gap; do the active node last as in section A.)
sudo -n kubectl exec -n openbao <node> -c openbao -- \
  mv /openbao/audit/audit.log /openbao/audit/audit.log.$(date +%Y%m%d)
sudo -n kubectl -n openbao delete pod <node>   # reopens audit.log at offset 0
# 3. Reset that node's anchor head so the next run baselines the new file at 0:
#    delete platform/openbao/<node>/_state.json in secforge-audit-anchors (the prior
#    anchors stay as the immutable, signed record of the rotated file).
```

(The rotated `audit.log.<date>` can be shipped to a versioned/object-locked MinIO
bucket if you want re-read capability for old ranges; the off-node signature already
proves them. **Automated** rotation — a logrotate sidecar + a generation-aware
anchor — stays a tracked follow-up; deferred because it's invasive to the crown-jewel
pod and the volume cut + 10 Gi make it non-urgent.)

## Follow-ups (operator-backlog #85)

- **Leader failover — DONE.** All three per-node files are anchored, so coverage
  survives any leadership move (no leader detection needed).
- **Automated rotation** (above) — tracked, non-urgent.
- **Phase 2.** A broad Loki anchor over the *other* security-critical namespaces
  (spire, kyverno, keycloak, spicedb, wazuh…) is the deferred Phase 2 — content-set
  hashing over a settled time window (Loki is not append-only). OpenBao audit, the
  crown jewel, is already covered by this Phase 1.

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
