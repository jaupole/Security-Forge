# Patches against vendored wazuh-1.2.10 chart

We vendored `ileonelperea/wazuh-helm` v1.2.10 in `./wazuh/` (see `.provenance`).
Each patch applied below carries the rationale + the exact change so a future
chart bump (re-pull from upstream) can re-apply or surface a conflict.

If you re-pull, run `git diff` against the upstream tarball, evaluate each
patch's continued necessity, and either re-apply or remove with a CHANGELOG
note.

---

## P-001 (2026-05-01) — Remove `NET_RAW` from manager capabilities

**File:** `wazuh/templates/manager/statefulset.yaml` (manager main container `securityContext.capabilities.add`)

**Before:**
```yaml
add:
  - CHOWN
  - DAC_OVERRIDE
  - FOWNER
  - KILL
  - NET_BIND_SERVICE
  - NET_RAW
  - SETGID
  - SETUID
  - SYS_CHROOT
```

**After:** `NET_RAW` removed (replaced by an explanatory comment in-line).

**Why:** Pod Security Standard `baseline` (the level we want for the wazuh
namespace per `infrastructure/wazuh/01-namespace.yaml`) **forbids** `NET_RAW`
in `capabilities.add`. The chart's default targets EKS-style namespaces which
don't enforce baseline.

**Impact:** Wazuh manager loses raw-socket access. Used in upstream Wazuh for:
- ICMP-based host discovery in active-response scripts
- Some `localfile` rule types that read raw network frames

We don't use either today (no agents, no active-response). If we add active-
response in Phase 7d alongside the agent DaemonSet, revisit: either restore
NET_RAW (and accept PSS=privileged for the agent SA only via per-pod exemption)
OR call upstream to gate NET_RAW behind a values flag.

**Maintenance:** if upstream gates this behind a values knob (e.g.
`manager.capabilities.add: [...]`) in a future release, drop this patch and
set the value via `infrastructure/wazuh/values.yaml` instead.

---

## P-002 (2026-05-01) — Remove `workload=wazuh` nodeSelector + matching toleration from cleanup CronJob

**File:** `wazuh/templates/cleanup/cronjob.yaml`

**Why:** Chart targets EKS Auto Mode node pools labeled `workload=wazuh`. Our
single-node local cluster has no such label/taint, so the cleanup pod is
stuck in `Pending` with `0/1 nodes are available: 1 node(s) didn't match Pod's
node affinity/selector`.

**Impact:** cleanup CronJob now schedules anywhere. Acceptable for local; in
cloud edition we'd re-introduce the nodeSelector + matching node label.

**Maintenance:** if upstream gates this behind `cleanup.nodeSelector` /
`cleanup.tolerations` values keys, drop this patch and set via
`infrastructure/wazuh/values.yaml` instead.

**Companion files (NOT patched today):**
- `wazuh/templates/indexer/cronjob-drift-detection.yaml` and
  `wazuh/templates/indexer/cronjob-watchdog.yaml` carry the same nodeSelector
  but render only when `indexer.driftDetection.enabled` / `indexer.watchdog.enabled`
  are true. We set both `false` in our values so the issue is moot. If a
  future operator flips them on, they'll need the same patch (or a values
  knob). Note this in the chart-bump checklist.
