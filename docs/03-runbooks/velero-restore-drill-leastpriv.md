# Velero restore drill — proving the least-privilege role (closes H-4.12)

> Architecture / config: [platform/values/velero.yaml](../../platform/values/velero.yaml),
> [platform/components/09a-velero.sh](../../platform/components/09a-velero.sh),
> [platform/manifests/velero/](../../platform/manifests/velero/)
> Companion: [dr-drill-tier1-findings.md](./dr-drill-tier1-findings.md) — that drill
> **explicitly excluded** Velero restore ("Velero restore-from-MinIO" listed under
> *What was NOT validated*). **This runbook fills that gap.**

## Scope

A repeatable **restore drill** that restores a real production backup into a throwaway
namespace and asserts it completes with **zero restore errors**, then tears the scratch
namespace down. Its purpose is narrow and specific:

**Prove that a least-privilege Velero RBAC role is sufficient to perform a full
namespace restore — including PodVolume (kopia filesystem) data — BEFORE H-4.12 is
declared closed.**

### Why this exists (the H-4.12 finding)

As of this writing the live cluster runs Velero with god-mode RBAC. Confirmed on
`secforge-prod`:

```text
$ sudo k3s kubectl get clusterrolebinding | grep velero
velero-server   ClusterRole/cluster-admin   …

$ sudo k3s kubectl get role velero-server -n velero -o yaml
rules:
- apiGroups: ['*']
  resources: ['*']
  verbs:     ['*']
```

That is the chart default (`vmware-tanzu/velero` 12.0.1 binds the server SA to
`cluster-admin`). It violates CLAUDE.md's bright line — *"Granting `cluster-admin` or
`*:*` RBAC to a service account"* is on the **Things that should NEVER happen** list —
and is the substance of **H-4.12**.

The fix is to replace the binding with a **scoped ClusterRole** enumerating only the
verbs/resources Velero actually touches during backup **and** restore. But a
hand-scoped role is worthless if it silently breaks restore — the one operation you
only find out about during a real disaster. **This drill is the gate**: scope the role,
run the drill, and only close H-4.12 when a representative restore reaches `Completed`
with `Errors: 0` under the least-privilege role.

> **The drill does NOT itself widen or narrow RBAC.** It is read + restore-into-scratch
> only. Scoping the role down is a separate, reviewed change (a `sec/` branch) that this
> drill *validates*. Per CLAUDE.md, do not "fix" the cluster-admin binding inside this
> runbook — propose the scoped role, apply it under review, then re-run this drill.

---

## Applying the scoped role (one-time migration)

> **Operator-run, gated.** This is the live cluster change H-4.12 calls for. Run it in a maintenance window; then run the drill below to validate **before** declaring H-4.12 closed.

**What this PR changes (steady-state GitOps):**
- `platform/manifests/velero/07-rbac-leastprivilege.yaml` — the scoped `velero-least-privilege` ClusterRole + a `velero-server` ClusterRoleBinding pointing at it (Strategy A: operator-owned binding).
- `platform/values/velero.yaml` — `rbac.create: true`, `rbac.clusterAdministrator: false`, `rbac.clusterAdministratorName: velero-least-privilege`.
- `platform/components/09a-velero.sh` — applies the RBAC manifest **after** the Helm step.

**Why the ordering matters.** Chart 12.0.1 renders the ClusterRoleBinding only when `rbac.create && rbac.clusterAdministrator` are *both* true. With `clusterAdministrator: false` the chart renders **no** binding, and a Helm upgrade **prunes** the existing chart-managed `velero-server -> cluster-admin` binding. roleRef is immutable, but a prune is a *delete* (not a patch), so this is exactly how we get off cluster-admin cleanly: Helm deletes the old binding, then the manifest creates the scoped one. Applying the manifest **before** Helm would hit the immutable-roleRef error; applying it **after** is correct.

**Pre-flight (read-only):**

```bash
ssh secforge "sudo k3s kubectl get clusterrolebinding velero-server -o jsonpath='{.roleRef.name}{\"\n\"}'"   # expect: cluster-admin
# confirm the chart renders NO binding under the new values (where helm + the values file are available):
helm template velero vmware-tanzu/velero --version 12.0.1 -f platform/values/velero.yaml -s templates/clusterrolebinding.yaml   # expect: empty
```

**Apply — pick ONE:**
- **Full (simplest):** re-run `platform/components/09a-velero.sh`. It does the Helm upgrade (prunes the old binding) then applies `07-rbac-leastprivilege.yaml`. Heavier — it also re-runs MinIO credential provisioning and fires an initial on-demand backup.
- **Surgical:** `helm upgrade --install velero vmware-tanzu/velero --version 12.0.1 -n velero --wait -f <rendered values>` (prunes the old cluster-admin binding), then **immediately** `sudo k3s kubectl apply -f platform/manifests/velero/07-rbac-leastprivilege.yaml`.

**Timing / blast radius.** The only window where Velero loses *cluster-scoped* permission is the few seconds between the Helm prune and the manifest apply — keep them back-to-back. The namespaced `velero-server` Role (`*/*/*` in ns velero, chart-managed, intentionally kept) is untouched, so in-namespace work — the hourly kopia repo-maintenance Jobs, leader-election leases — **survives** the window. A cluster-wide **backup or restore** that starts in that window could fail, so **avoid 01:45–02:15 and 02:45–03:15 UTC** (daily 02:00, weekly Sun 03:00). Pausing the schedules first (`kubectl -n velero patch schedule ... paused:true`) is optional belt-and-suspenders and is a *write* needing explicit authorization.

**Post-apply verify:**

```bash
ssh secforge "sudo k3s kubectl get clusterrolebinding velero-server -o jsonpath='{.roleRef.name}{\"\n\"}'"   # expect: velero-least-privilege
ssh secforge "sudo k3s kubectl -n velero logs deploy/velero --since=5m | grep -iE 'forbidden|cannot' || echo 'no RBAC denials'"
```

Then **run the drill below.** Backups keep working (read-all is proven complete); the drill is what proves *restore* completeness under the scoped role.

**Rollback (fast).** `kubectl delete clusterrolebinding velero-server` then re-apply a `velero-server -> cluster-admin` binding (keep a pre-saved `kubectl get clusterrolebinding velero-server -o yaml` from pre-flight), **or** revert the `rbac` block in `values/velero.yaml` and `helm upgrade` (chart re-creates the cluster-admin binding). The SA token is unchanged, so no pod restart is needed — effective RBAC updates immediately. Unpause schedules if paused. Never rollback by re-adding `*` verbs to the scoped role.


## Prerequisites

- SSH to the node. Cluster access is read-only by default:
  `ssh secforge 'sudo k3s kubectl …'`. The restore *itself* is a write — it is the
  one authorized, targeted prod write this drill performs, and it lands **only** in the
  scratch namespace `velero-restore-drill`.
- The `velero` CLI. It is **not** on the host `PATH`; invoke the one baked into the
  server image:
  ```bash
  ssh secforge 'sudo k3s kubectl -n velero exec deploy/velero -- /velero version --client-only'
  # Client: Version: v1.18.0
  ```
  Every `velero …` command below is shorthand for
  `sudo k3s kubectl -n velero exec deploy/velero -- /velero …`.
- `BackupStorageLocation default` is `Available`:
  ```bash
  ssh secforge 'sudo k3s kubectl get backupstoragelocation default -n velero'
  # NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
  # default   Available   …               …     true
  ```
- The `node-agent` DaemonSet pod is `Running` (it performs the kopia FSB restore via
  `PodVolumeRestore`; without it, PVC data is never rehydrated):
  ```bash
  ssh secforge 'sudo k3s kubectl get pods -n velero -l name=node-agent'
  # node-agent-xxxxx   1/1   Running
  ```
- The candidate **least-privilege ClusterRole has already been applied** and the
  `velero-server` ClusterRoleBinding points at it (not `cluster-admin`). If you are still
  running the chart default, this drill will trivially pass — it proves nothing. The
  whole point is to run it *after* the scope-down so a missing verb surfaces as a
  restore error.

---

## Pick a representative backup (must carry PodVolume data)

List what's actually in object storage (this reads the BSL, not the cluster — note that
`kubectl get backup -n velero` can come back empty because the Backup CRs are TTL-GC'd
from the cluster while the data lives on in MinIO):

```bash
ssh secforge 'sudo k3s kubectl -n velero exec deploy/velero -- /velero backup get'
```

Pick a backup that is **`Completed` with `ERRORS 0`** — never a `PartiallyFailed` one,
or you can't tell a restore error from a pre-existing backup gap. On the current cluster,
good candidates were `weekly-platform-20260531030032` and `daily-everything-20260531020032`
(both `Completed`, `0` errors). Confirm the chosen backup actually contains **PodVolume
(kopia FSB) data** — that is the load-bearing part of the drill, because FSB restore is
the path most likely to need an RBAC verb the scoped role forgot:

```bash
BK=weekly-platform-20260531030032   # ← set to your chosen Completed/0-error backup

ssh secforge "sudo k3s kubectl get podvolumebackups -n velero \
  -l velero.io/backup-name=$BK \
  -o custom-columns=NS:.spec.pod.namespace,POD:.spec.pod.name,VOL:.spec.volume,STATUS:.status.phase,BYTES:.status.progress.bytesDone \
  | grep -E 'member-hub|NS'"
```

You want to see `Completed` PVBs with non-trivial `BYTES` (e.g. `member-hub  member-hub-db-1  pgdata  Completed  622329886`). That proves the backup carries real
filesystem data to restore, not just manifests.

### Representative target namespace: `member-hub`

`member-hub` is chosen because it exercises **all five object classes** the least-priv
role must be able to restore, all present in the backup above:

| Class | Concrete object in `member-hub` |
|---|---|
| Deployment | `deployment.apps/member-hub` |
| Secret | `secret/member-hub-app-secrets` (7 keys) |
| PVC + kopia FSB data | `pvc/member-hub-db-1` → volumes `pgdata` (~622 MB) + `scratch-data` (PVB `Completed`) |
| RBAC object | `role.rbac.authorization.k8s.io/member-hub-db` + its RoleBinding |
| CRD instance | `vaultstaticsecret.secrets.hashicorp.com/member-hub-app-secrets`, `vaultauth.secrets.hashicorp.com/member-hub-audit-signer` |

> **CNPG caveat (read before running).** `member-hub-db-1` is a PVC owned by a CloudNativePG
> `Cluster`. Restoring it into a *mapped* namespace gives you the **PVC + its bytes back via
> the kopia FSB path** — which is exactly what this drill asserts — but the CNPG **operator
> will not adopt** a Cluster in a namespace it isn't watching, so the restored DB pod may not
> come back up. **That is expected and is NOT a restore error.** This drill validates *Velero's
> ability to restore the objects + rehydrate volume data under the least-priv role*, not
> CNPG's cross-namespace reconciliation. If you want a restore target with zero operator
> entanglement, swap in an app namespace whose PVC is plain `local-path` and not
> operator-owned; the procedure is identical. Either way the pass/fail gate is the same:
> **`velero restore describe` shows `Errors: 0`.**

---

## Procedure

All commands run via `ssh secforge 'sudo k3s kubectl -n velero exec deploy/velero -- /velero …'`.
Set the two variables once at the top of your session:

```bash
BK=weekly-platform-20260531030032            # Completed, 0-error backup with PVB data
SRC=member-hub                               # source namespace in the backup
DST=velero-restore-drill                     # scratch target — created by the restore
RESTORE="drill-${SRC}-$(date -u +%Y%m%d-%H%M%S)"
```

### 1. Pre-flight — assert the scratch namespace does NOT already exist

The drill must create the namespace fresh so cleanup is a clean `delete ns`. Abort if it
exists (a leftover from a prior run pollutes the result):

```bash
ssh secforge "sudo k3s kubectl get ns $DST" 2>&1
# EXPECT: Error from server (NotFound): namespaces "velero-restore-drill" not found
```

If it exists, run the **Cleanup** section first, confirm it's gone, then continue.

### 2. Create the restore with a namespace mapping into the scratch namespace

`--namespace-mappings $SRC:$DST` rewrites every namespaced object from `member-hub` into
`velero-restore-drill` on the way in. `--include-namespaces` keeps the restore scoped to
just the source namespace (cluster-scoped objects like the CRD *definitions* are assumed
present — we restore CRD **instances**, not the CRDs themselves, which already exist on a
live cluster).

```bash
ssh secforge "sudo k3s kubectl -n velero exec deploy/velero -- /velero restore create $RESTORE \
  --from-backup $BK \
  --include-namespaces $SRC \
  --namespace-mappings $SRC:$DST \
  --existing-resource-policy=none \
  --wait"
```

`--wait` blocks until the restore leaves the `InProgress` phase. The
`--existing-resource-policy=none` is belt-and-suspenders: into a brand-new namespace there
is nothing to collide with, so nothing is skipped for "already exists" reasons — every
skip would be a real signal.

### 3. Assert the restore reached `Completed` with ZERO errors — the gate

```bash
ssh secforge "sudo k3s kubectl -n velero exec deploy/velero -- /velero restore describe $RESTORE --details" \
  | grep -E 'Phase|Errors|Warnings|Total items|Items restored'
```

Read the result against the gate:

- **`Phase: Completed`** — required. `PartiallyFailed` or `Failed` is an automatic FAIL.
- **`Errors: 0`** — **required and non-negotiable.** Any non-zero error count fails the
  drill (see *Pass/fail gate* and *When a restore error means the role is missing a verb*).
- **Warnings** — inspect, but warnings about already-existing cluster-scoped objects or
  Succeeded-pod volume skips are benign. Warnings are not a FAIL on their own; errors are.

Also dump the full error block explicitly so a non-zero count can't hide:

```bash
ssh secforge "sudo k3s kubectl get restore $RESTORE -n velero \
  -o jsonpath='{.status.phase}{\"\n\"}errors={.status.errors}{\"\n\"}warnings={.status.warnings}{\"\n\"}'"
# WANT: Completed / errors=0 / warnings=<n>
```

### 4. Confirm the kopia FSB data path ran clean (PodVolumeRestore)

The PVC bytes come back via `PodVolumeRestore` objects driven by the node-agent. These are
where a missing `podvolumerestores`/`datadownloads` verb in a too-tight role shows up:

```bash
ssh secforge "sudo k3s kubectl get podvolumerestores -n velero \
  -l velero.io/restore-name=$RESTORE \
  -o custom-columns=POD:.spec.pod.name,VOL:.spec.volume,STATUS:.status.phase,BYTES:.status.progress.bytesDone"
# WANT: every row STATUS=Completed with BYTES matching the backup-side PVB
```

If this list is **empty** but the backup had PVBs, the node-agent never got told to
restore — that is itself a failure mode (often a missing
`get/list/watch/create/update podvolumerestores` or `datadownloads` verb on the role).

### 5. Validate a sample of restored objects in the scratch namespace

Confirm each of the five object classes actually landed and is intact.

**5a. Deployment** — present, spec restored:

```bash
ssh secforge "sudo k3s kubectl get deploy member-hub -n $DST -o jsonpath='{.spec.replicas} replicas, image={.spec.template.spec.containers[0].image}{\"\n\"}'"
# WANT: the Deployment exists with its original replica count + image
```

**5b. Secret** — present with the right key count and non-empty data:

```bash
ssh secforge "sudo k3s kubectl get secret member-hub-app-secrets -n $DST \
  -o jsonpath='{.type} keys={.data}' | head -c 200; echo
ssh secforge \"sudo k3s kubectl get secret member-hub-app-secrets -n $DST -o jsonpath='{.data}' | tr ',' '\n' | wc -l\""
# WANT: type Opaque, 7 keys present (matches source)
```

> Do not print Secret *values* to the terminal. Asserting **presence + key count + non-zero
> length** is sufficient validation and keeps secret material out of your scrollback and any
> session transcript.

**5c. PVC + its data (kopia FSB path)** — PVC bound, and its restored bytes are real.
Validate the bytes by execing into the node-agent's view or, more simply, by confirming the
PVC is `Bound` and the matching `PodVolumeRestore` reported the expected `bytesDone`
(step 4). To assert *file content* rather than just byte count, mount the restored PVC in a
throwaway reader pod **in the scratch namespace** and stat the data dir:

```bash
ssh secforge "sudo k3s kubectl get pvc -n $DST \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAP:.status.capacity.storage"
# WANT: member-hub-db-1 (or your chosen PVC) STATUS=Bound
```

> The byte-count match between the backup-side `PodVolumeBackup` (step "Pick a backup") and
> the restore-side `PodVolumeRestore` (step 4) is the primary data-integrity assertion for
> the FSB path. A reader-pod content check is optional gold-plating; if you do it, delete the
> reader pod before cleanup.

**5d. RBAC object** — the Role and its RoleBinding restored, rules intact:

```bash
ssh secforge "sudo k3s kubectl get role member-hub-db -n $DST -o jsonpath='{.rules}{\"\n\"}'"
ssh secforge "sudo k3s kubectl get rolebinding member-hub-db -n $DST -o jsonpath='{.roleRef.name} -> {.subjects}{\"\n\"}'"
# WANT: Role rules present; RoleBinding references the restored Role + original subjects
```

> RBAC objects are a deliberate part of the sample: a least-priv role missing
> `rbac.authorization.k8s.io` verbs (`roles`, `rolebindings`) restores everything *except*
> RBAC and the gap is invisible unless you check.

**5e. CRD instance** — a custom resource restored (CRD definition already exists cluster-wide):

```bash
ssh secforge "sudo k3s kubectl get vaultstaticsecret member-hub-app-secrets -n $DST -o jsonpath='{.kind}/{.metadata.name}{\"\n\"}'"
ssh secforge "sudo k3s kubectl get vaultauth member-hub-audit-signer -n $DST -o jsonpath='{.kind}/{.metadata.name}{\"\n\"}'"
# WANT: VaultStaticSecret/member-hub-app-secrets and VaultAuth/member-hub-audit-signer present
```

> CRD instances are in the sample because restoring `secrets.hashicorp.com` (VSO) resources
> requires the role to carry that apiGroup. SYNCED/READY status on the restored VSS may be
> `False` in the scratch namespace (no matching VSO auth role there) — **that is expected and
> not a restore error.** We are validating that Velero *restored the object*, not that VSO
> reconciles it cross-namespace.

### 6. Capture restore logs for the record (and to confirm no silent error)

```bash
ssh secforge "sudo k3s kubectl -n velero exec deploy/velero -- /velero restore logs $RESTORE" \
  | grep -iE 'error|forbidden|cannot|denied' | grep -v 'level=info' | head -40
# WANT: no 'forbidden' / 'cannot ... is forbidden' / RBAC-denied lines.
#       'is forbidden: User "system:serviceaccount:velero:velero-server" cannot ...'
#       is the EXACT signature of a missing verb in the least-priv role.
```

---

## Pass/fail gate

The drill **PASSES** — and only then may H-4.12 be closed — when **all** of the following
hold for a backup that was itself `Completed` with `0` errors:

1. `velero restore describe $RESTORE` shows **`Phase: Completed`**.
2. **`Errors: 0`.** (`status.errors == 0`.) This is the headline gate.
3. Every `PodVolumeRestore` for the restore is `Completed`, with `bytesDone` matching the
   backup-side `PodVolumeBackup` for the same volume (kopia FSB path proven end-to-end).
4. All five sampled object classes are present and intact in the scratch namespace:
   Deployment (spec + replicas), Secret (type + key count), PVC (`Bound` + data bytes),
   RBAC (Role rules + RoleBinding ref), CRD instance.
5. `velero restore logs $RESTORE` contains **no `forbidden` / RBAC-denied lines**.

If **any** of 1–5 fails, the drill **FAILS** and H-4.12 stays open.

> **0-restore-errors completeness gate:** `velero restore describe` must report
> `Errors: 0` (equivalently `status.errors == 0`) for a restore of a known-good
> (`Completed`, 0-error) backup that carries PodVolume data, restored into the
> `velero-restore-drill` scratch namespace under the **least-privilege** `velero-server`
> role — with all five sampled object classes restored intact and no `forbidden` lines in
> the restore log. A single restore error of any kind blocks closure of H-4.12.

---

## When a restore error means the role is missing a verb/resource/subresource

**Any restore error under the least-priv role is treated as a role gap until proven
otherwise.** Velero surfaces RBAC denials as restore errors of the form:

```text
error restoring <kind>/<ns>/<name>: <resource>.<group> is forbidden:
User "system:serviceaccount:velero:velero-server" cannot create resource
"<resource>" in API group "<group>" in the namespace "velero-restore-drill"
```

The remediation loop is deterministic:

1. **Read the error.** It names the exact `resource`, `apiGroup`, and `verb`
   (`create`/`get`/`list`/`patch`/`update`/`delete`) that was denied — and sometimes a
   **subresource** (e.g. `pods/exec`, `*/finalizers`, `serviceaccounts/token`).
2. **Add precisely that tuple** to the candidate least-privilege ClusterRole — the missing
   `{apiGroups, resources, verbs}` and nothing wider. Common ones the restore path needs
   beyond the obvious workload kinds: `persistentvolumeclaims`, `persistentvolumes`,
   `podvolumerestores.velero.io`, `datadownloads.velero.io`, `restores.velero.io`,
   `*/finalizers`, and the `rbac.authorization.k8s.io` group (`roles`, `rolebindings`,
   `clusterroles`, `clusterrolebindings`).
3. **Re-apply the role** (under review, on the `sec/` branch — never widen RBAC inside this
   runbook), **clean up the scratch namespace**, and **re-run the entire drill from step 1.**
4. Repeat until the drill PASSES with `Errors: 0`. **Do NOT** close H-4.12 on a
   `PartiallyFailed` restore, and **do NOT** paper over a denial by reverting to
   `cluster-admin` or adding `*` verbs/resources — that re-introduces the exact finding
   H-4.12 exists to remove.

> Re-drill discipline mirrors CLAUDE.md's advisor loop: a failed gate routes to a *scoped*
> fix (one verb/resource/subresource), then the **full** gate re-runs. No partial credit.

---

## Cleanup (always run — leaves zero residue)

The scratch namespace and the restore record are both disposable. Tearing down the
namespace cascades all restored objects; deleting the Restore CR removes the bookkeeping.

```bash
# 1. Delete the scratch namespace (cascades Deployment, Secret, PVC, RBAC, CRD instances).
ssh secforge "sudo k3s kubectl delete ns $DST --wait=true"

# 2. If a CNPG/operator-owned PVC's PV lingered as Released, confirm it's gone
#    (local-path PVs are Delete-reclaim, so they go with the PVC; verify nonetheless).
ssh secforge "sudo k3s kubectl get pv | grep $DST" || echo 'no lingering PVs — good'

# 3. Delete the Restore CR record (optional; keeps the velero ns tidy).
ssh secforge "sudo k3s kubectl delete restore $RESTORE -n velero"

# 4. Final assertion: scratch namespace is gone.
ssh secforge "sudo k3s kubectl get ns $DST" 2>&1
# EXPECT: Error from server (NotFound): namespaces "velero-restore-drill" not found
```

> The drill never touches the source namespace (`member-hub`), the backups, the BSL, or any
> RBAC binding. Its only write is the restore into `velero-restore-drill`, fully reversed by
> the namespace delete above.

---

## Recovery (if the drill itself wedges)

- **Restore stuck `InProgress`** past ~15 min: check the velero server log
  (`sudo k3s kubectl logs -n velero deploy/velero --tail=80`) and the node-agent log for the
  FSB restore. A wedged restore can be abandoned by deleting the Restore CR (step 3 of
  Cleanup) and the partial scratch namespace (step 1); no source data is at risk.
- **Scratch namespace stuck `Terminating`** on a finalizer (often a CNPG `Cluster` or a VSS
  with a finalizer the operator isn't reconciling cross-namespace): inspect with
  `kubectl get ns $DST -o jsonpath='{.spec.finalizers}'` and the namespaced CRs'
  `metadata.finalizers`. Resolve the owning operator's finalizer rather than force-removing
  namespace finalizers. This is also a signal that the *source* namespace has operator-owned
  resources you may want to exclude from the next drill's `--include-resources`.
- **`velero` CLI exec fails** because the server pod is mid-roll (the velero Deployment has
  been seen with many `Evicted` replicas on this single node): wait for the one `Running`
  `velero-*` pod, or target it directly with
  `kubectl -n velero exec <running-pod> -c velero -- /velero …`.

---

## Last tested

Not yet executed against the least-privilege role — **this runbook is the gate that must
pass before H-4.12 can be closed.** Record the date, the chosen backup name, the restore
name, and the `Errors: 0` evidence here on first successful run. Per the runbooks README,
re-walk this drill quarterly; if untested for 6 months, treat the least-priv role as
unproven until re-drilled.
