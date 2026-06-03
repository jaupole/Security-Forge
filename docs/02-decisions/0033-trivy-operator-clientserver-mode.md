# ADR-0033: Trivy Operator runs in ClientServer mode (built-in trivy-server)

- **Status:** Accepted — applied 2026-06-03
- **Date:** 2026-06-03

## Context
Trivy Operator was deployed in **Standalone** mode. In Standalone, the operator
creates one scan `Job` per workload, and inside that Job it runs **one `trivy
image` container per container-image, concurrently, all sharing a single
`--cache-dir /tmp/trivy/.cache` emptyDir**. Trivy keeps its vulnerability DB in a
BoltDB file guarded by a filesystem lock, so the sibling containers race for that
lock:

```
FATAL  unable to initialize cache: unable to initialize fs cache:
       cache may be in use by another process: timeout
```

The loser(s) exit 1 → the Job fails (backoff exhausted) → `kube_job_failed=1` →
the **`KubeJobFailed` / `trivy-system`** alert fires. With `scanJobTTL=30m` the
operator re-creates the job each interval, so it re-failed and re-emailed roughly
**every 30 minutes, all night** (an overnight inbox flood that buried genuine
alerts — a `VeleroBackupTooOld` critical was in the same batch).

It hits **multi-image pods** hardest: every CloudNativePG database pod carries
three images (`postgres` + `cloudnative-pg` + `plugin-barman-cloud-sidecar`), and
`topolvm-controller` carries many. It is a **race**, so it is intermittent — some
intervals win (keycloak-db, member-hub-db got all three reports), others lose
(spicedb-db, topolvm-controller, proposal-forge-db sidecars). The failures also
leave **intermittent CVE-scan gaps** on those sidecar images.

This is distinct from the two earlier `KubeJobFailed` causes already fixed: the
Velero kopia-job churn (dropped `job` from `targetWorkloads`) and the private
keycloak-image scan-DENIED (moved to build-time scanning). Standalone offers no
"serialize the containers within a Job" knob, so neither tuning nor concurrency
limits address this one.

## Decision
Switch Trivy Operator to **ClientServer** mode using the chart's **built-in
trivy-server** (`operator.builtInTrivyServer: true`, `trivy.mode: ClientServer`
in `platform/values/trivy-operator.yaml`).

The chart then renders a single long-lived **`trivy-server` StatefulSet** + a
`trivy-service` Service on `:4954`, and auto-wires the operator's
`trivy.serverURL` to it. The vulnerability DB lives in **one** process; scan Jobs
become **thin clients** (`trivy image --server …`) that hold **no local DB
cache** — so the per-Job cache-lock contention is **structurally** eliminated,
not merely made less likely.

- **Storage:** the server keeps its ~1 GB DB on a **5 Gi PVC** (chart default,
  default StorageClass `local-path`). A PVC (vs emptyDir) is deliberate: a server
  restart must **not** re-download the DB, because that re-download window would
  leave client scans failing and could itself flap `KubeJobFailed` — defeating
  the fix.
- **NetworkPolicy:** ClientServer adds an in-cluster hop the egress baseline
  never needed — the operator (pre-dispatch health-check) and every scan-Job
  client must reach `trivy-service:4954`. The `trivy-system` egress baseline
  (`default-deny-egress` + DNS + K8s API + public `:443` for the DB) does **not**
  cover it, so `09-egress-trivy-server.yaml` allows trivy-system pods →
  trivy-server `:4954`. Without it the operator never dispatches scans (symptom:
  zero scan Jobs). Standalone didn't need this — net-new with the cutover.
- **Posture:** the server pod runs `runAsUser: 65534`, `runAsNonRoot: true`,
  `readOnlyRootFilesystem: true`, `automountServiceAccountToken: false` (chart
  defaults). It passes `pss-baseline`, `require-run-as-nonroot`, and
  `restrict-image-registries` (image `mirror.gcr.io/aquasec/trivy:0.69.3`, an
  allowlisted registry). `require-image-digest` is `Audit`, consistent with the
  existing operator/scan-job images.

The whole live state remains reproducible from
`platform/components/13-trivy-operator.sh` + `platform/values/trivy-operator.yaml`
(chart pinned `0.32.1`).

## Consequences
- **One new StatefulSet + Service + 5 Gi PVC** in `trivy-system`. Net node
  footprint is roughly flat-to-lower: the server holds the DB once instead of
  every scan Job re-initialising its own cache, and client scan Jobs are lighter.
- **Coverage is now reliable** for multi-image CNPG/topolvm pods — the sidecar
  images that intermittently went unscanned are scanned every interval.
- **Server restart** re-warms from the PVC (fast); only a PVC loss forces a full
  DB re-download. Server `/healthz` gates readiness, so the operator waits.
- **Revert** = set `operator.builtInTrivyServer: false` + `trivy.mode:
  Standalone`, then delete `StatefulSet/trivy-server`, `Service/trivy-service`,
  and `PVC/data-trivy-server-0` (StatefulSet PVCs are not garbage-collected).
## Residual: multi-image `/tmp` collision (separate cause, NOT fixed by this)
ClientServer eliminates the **DB/cache-lock** race — the dominant, every-30-min,
all-night cause. It does **not** fix a *second, independent* failure behind the
same alert: trivy-operator scans each image of a multi-image pod as **sibling
containers in one Job pod that share a single `/tmp` emptyDir**, and concurrent
trivy processes collide there (`unable to create temporary directory: …/tmp/trivy-N:
no such file or directory`). It is **intermittent** (a race): the 3-image CNPG DB
pods sometimes win — keycloak-db and member-hub-db get all three reports — and
sometimes lose (proposal-forge-db, spicedb-db end up partial). The heaviest
multi-image targets (the five CNPG DBs, `control-billing-usage-sync`) lose often
enough that `KubeJobFailed` still flaps **occasionally** — far less than before,
but not zero.

This is **not values-fixable** in chart 0.32.1: `scanJobsConcurrentLimit` is
per-Job, not per-container; there is no within-Job serialization knob; and the
shared `/tmp` exists *because* the scan containers run `readOnlyRootFilesystem:
true`, which we will not weaken.

**Decision (2026-06-03):** route `KubeJobFailed{namespace="trivy-system",
job_name=~"scan-vulnerabilityreport-.*"}` to the Alertmanager **blackhole**
receiver (`platform/manifests/observability/13-alertmanager-email.yaml`) — it is
known-flaky operator churn on stock CNPG/topolvm images, kept visible+firing in
Alertmanager but off the inbox. The scope is deliberately tight: real
app-namespace Job failures still email, and a trivy-**server** outage surfaces as
its own StatefulSet alert (not a scan-Job `KubeJobFailed`), so server health is
not silenced. A chart bump (0.33.1 / trivy-operator 0.31.1) is the open upstream
lever if multi-image temp handling improves there.
