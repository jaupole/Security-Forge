# Runbook: SPIRE SVID Rotation and Recovery

> **Production note.** Written for the local edition. In production the SPIRE trust domain is **`secforge.platform`** and the cluster is **Hetzner k3s** single node. Verify steps against the live cluster before acting. See [PLAN.md](../../PLAN.md).

This is for **operational rotation** of SVIDs and recovery from common SPIRE problems. For the every-decade upstream-CA rotation, see [spire-ca-rotation.md](./spire-ca-rotation.md).

**Companion docs:**
- Architecture: [docs/01-architecture/06-workload-identity.md](../01-architecture/06-workload-identity.md)
- ADR: [docs/02-decisions/0005-spire-architecture-local.md](../02-decisions/0005-spire-architecture-local.md)
- Helm values: `infrastructure/spire/values.yaml`
- Registrations: `infrastructure/spire/cluster-spiffe-ids.yaml`

---

## Normal rotation behavior (no operator action)

- **X.509-SVID** (1h TTL): the agent refreshes at 50% TTL — every ~30 minutes.
- **JWT-SVID** (5m TTL): issued on demand by the workload, never cached on disk.
- **CA intermediate** (24h TTL): rotates daily. Workloads' SVID chains automatically include the latest signing certificate.
- **Trust bundle**: pushed to the `spire-bundle` ConfigMap on every change. Agents re-read it within seconds.

If everything is working, you should never need to touch SPIRE for SVID rotation. The runbook below is for when something goes wrong.

---

## Quick health check

```bash
# All three pods Ready?
kubectl get pods -n spire

# Server can accept entries from the controller-manager?
kubectl logs -n spire deploy/spire-spire-controller-manager --tail=10 \
  | grep -iE "error|warning"

# Agent attested to the server?
kubectl logs -n spire ds/spire-agent --tail=20 \
  | grep -iE "Node attestation was successful|create UDS listener"

# A known workload still has a registration?
kubectl exec -n spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show -spiffeID spiffe://secforge.platform/ns/test-spire/sa/test-app

# Trust bundle exposed?
kubectl exec -n spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server bundle show -format spiffe \
  | head -3
```

---

## Issue: a workload reports `PermissionDenied: no identity issued`

**Most common causes:**
1. The pod doesn't carry the opt-in label `spiffe.io/spire-managed-identity: "true"`, *and* its namespace isn't covered by a namespace-scoped `ClusterSPIFFEID`.
2. The controller-manager hasn't yet reconciled the pod (typically within 30 seconds; can be longer right after pod creation).
3. The pod's ServiceAccount differs from what the registration matches on.

**Diagnose:**

```bash
# Confirm the pod is selected by some ClusterSPIFFEID
kubectl get clusterspiffeid -o yaml \
  | yq '.items[] | select(.spec.podSelector.matchLabels."spiffe.io/spire-managed-identity" == "true" or .spec.namespaceSelector != null)'

# Check whether SPIRE has minted an entry for this pod's UID
POD_UID=$(kubectl get pod -n <ns> <pod> -o jsonpath='{.metadata.uid}')
kubectl exec -n spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show -selector "k8s:pod-uid:$POD_UID"

# Check the agent's view
kubectl logs -n spire ds/spire-agent --tail=50 | grep -i "no identity"
```

**Fix:**
- Add the opt-in label, OR confirm the namespace is in `infrastructure/spire/cluster-spiffe-ids.yaml`.
- Wait ~30s for the controller-manager to reconcile.
- Verify the SA name matches the registration template's `{{ .PodSpec.ServiceAccountName }}` expansion.

---

## Issue: SVIDs are not rotating (workload's SVID NotAfter is past)

**Most common causes:**
1. The agent is wedged. Restart it: `kubectl rollout restart ds -n spire spire-agent`.
2. The workload caches the SVID and never asks for a new one. Every workload using `go-spiffe/v2` should use `WorkloadAPISource` or `X509Source` which auto-refresh.
3. The CA intermediate has expired (very rare; we use 24h CA TTL with 5m JWT TTL — a multi-day server outage would cause this).

**Diagnose:**

```bash
# What does the agent think the SVID looks like?
kubectl exec -n <ns> <pod> -c <container> -- /spiffe-test 2>&1 | head -10
# (Or any program in the pod that reads the CSI mount.)

# Server's view of the entry's revision count — should advance over time.
kubectl exec -n spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show -spiffeID spiffe://...
```

**Fix:**
- Roll the agent: `kubectl delete pod -n spire -l app.kubernetes.io/component=agent --force --grace-period=0`. The DS will recreate it; existing workload pods that mount the CSI volume will reconnect to the new agent transparently.
- If multiple agents are wedged in the same way, the controller-manager may be the issue — `kubectl rollout restart statefulset -n spire spire-server`.

---

## Issue: CA intermediate expired (server has been down > ca_ttl)

**Symptoms:** every workload starts failing to validate SVIDs of every other workload, simultaneously, after a server outage.

**Recovery:**

```bash
# Bring the server back up.
kubectl scale statefulset -n spire spire-server --replicas=1
kubectl rollout status statefulset -n spire spire-server

# Force agents to re-fetch the trust bundle.
kubectl rollout restart ds -n spire spire-agent

# Workloads will re-fetch SVIDs on next rotation; for an immediate fix, restart them.
kubectl rollout restart -n <ns> deploy/<name>
```

If the spire-server PVC has been deleted (datastore lost), follow the bootstrap-from-scratch procedure in [spire-ca-rotation.md § Recovery](./spire-ca-rotation.md#recovery-i-deleted-the-upstream-ca-secret-by-mistake).

---

## Issue: agent crashloops with `bind: permission denied` on the workload API socket

**Cause:** the `fsgroupfix` init container hasn't run, or its chown didn't apply (e.g., values.yaml was changed to remove `fsGroup`). The agent's UID 1000 cannot create the UDS in `/tmp/spire-agent/private/` because that directory is owned by root.

**Fix:** ensure `infrastructure/spire/values.yaml` has all three of `runAsUser: 1000`, `runAsGroup: 1000`, **and** `fsGroup: 1000` under `spire-agent.podSecurityContext`. Re-apply with `helm upgrade`.

---

## Issue: spire-server crashes on startup with `unsupported private key type ed25519.PrivateKey`

**Cause:** the upstream CA in `spire-upstream-ca` was generated with an Ed25519 algorithm. SPIRE's `disk` UpstreamAuthority plugin (1.14.x) supports RSA and ECDSA only.

**Fix:** regenerate the upstream CA using `openssl ecparam -name prime256v1` (P-256) or `openssl genrsa -out ... 2048` (RSA). Update the K8s Secret with `tls.crt` and `tls.key` keys (those are the names the chart's volume mount expects). See [spire-ca-rotation.md](./spire-ca-rotation.md).

---

## Issue: ResourceQuota errors on spire-server pod creation

**Cause:** the `spire` namespace's `default-quota` is too small. The Phase 1 baseline (1 CPU / 1Gi) is below SPIRE's requirements (~1.4 CPU / 1.4Gi total across server + agent + CSI + controller-manager). The Phase 2 update is 2 CPU / 2Gi.

**Fix:** apply the updated quota:

```bash
kubectl apply -f infrastructure/namespaces/namespaces.yaml
# Then nudge the StatefulSet to retry pod creation:
kubectl rollout restart statefulset -n spire spire-server
```

---

## Issue: chart's pre-install/upgrade hooks fail with `runAsNonRoot policy violation`

**Cause:** the chart's `installAndUpgradeHooks` use a kubectl image that runs as root, but our pod-level securityContext sets `runAsNonRoot: true`.

**Fix:** the values file has `global.installAndUpgradeHooks.enabled: false`. We manage installs/upgrades manually. Use `helm upgrade ... --no-hooks` to avoid re-triggering them on subsequent upgrades.

---

## Issue: image-pull failures on busybox / chainguard images

**Cause:** chart init containers (`chown` for spire-server PVC; `fsgroupfix` and `ensure-alternate-names` for spire-agent) pull from Docker Hub / ghcr. Transient registry flakiness can break startup.

**Fix:**
- For spire-server, the chart skips `chown` if you explicitly set `runAsUser` in the user-supplied podSecurityContext. We do that.
- For spire-agent, the init containers are unavoidable when fsGroup is used. Wait for the pull to retry (Kubernetes backoff is exponential up to ~5min) or pre-pull manually:
  ```bash
  docker pull cgr.dev/chainguard/bash:latest
  docker save cgr.dev/chainguard/bash:latest \
    | docker exec -i desktop-control-plane ctr -n=k8s.io images import -
  ```

---

## Issue: cold-boot race after Docker Desktop restart — pods CrashLoop with `MountVolume.SetUp failed` for `csi.spiffe.io`

**Symptom.** After every Docker Desktop / Kubernetes restart, one or more SPIFFE-consuming workloads (OpenBao, helloworld-bff, authzen-facade, anything that mounts the SPIFFE-CSI volume) lands in `CrashLoopBackOff` or `ContainerCreating` with events like:

```
MountVolume.SetUp failed for volume "spiffe-workload-api" : kubernetes.io/csi: mounter.SetUpAt failed to get CSI client: driver name csi.spiffe.io not found in the list of registered CSI drivers
```

…or, after the mount eventually succeeds, the main container starts and immediately fails because the JWT-SVID written by the `spiffe-helper` init container has already expired.

**Cause.** Cluster boot is concurrent. The SPIRE agent DaemonSet, the `spiffe-csi-driver` DaemonSet, and workload pods all schedule roughly in parallel. Kubelet only registers `csi.spiffe.io` once the CSI driver pod's registration sidecar comes up — typically 60–90s into boot. During that window, kubelet rejects every CSI volume mount referencing `csi.spiffe.io`. Workload pods enter exponential backoff (5min, 10min, …). The init container that *does* eventually run mints a JWT-SVID with 5-min TTL; if the main container's restart is delayed past that, the SVID is already stale by the time it's read.

This is local-edition specific. Cloud K8s schedulers and DaemonSet rollout ordering avoid it (and PriorityClasses on managed-K8s system DaemonSets give them head-start anyway). On Docker Desktop's single node we get the race every cold boot.

**Triage.**

```bash
# Which pods are stuck?
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Confirm the mount-failure shape
kubectl describe pod -n openbao openbao-0 | grep -A2 'MountVolume\|csi.spiffe.io'

# Is the CSI driver registered yet?
kubectl get csidriver csi.spiffe.io -o jsonpath='{.metadata.creationTimestamp}'
kubectl get pods -n spire -l app.kubernetes.io/name=spiffe-csi-driver
```

If `csi.spiffe.io` is registered and the SPIFFE-CSI pods are Ready, the race is over — the affected workload pods are just stuck in backoff and won't recover until poked.

**Manual fix (today's workaround).**

```bash
# Delete the affected pods so kubelet creates fresh ones with current SVIDs.
# The CSI driver is now registered, so the new pods mount cleanly.
kubectl delete pod -n openbao openbao-0 openbao-1 openbao-2
kubectl delete pod -n openbao openbao-seal-0
kubectl delete pod -n app -l app=helloworld-bff
kubectl delete pod -n app -l app=authzen-facade

# After OpenBao pods come back, unseal main from seal:
bash infrastructure/openbao/unseal-seal.sh
```

The `unseal-seal.sh` step is the existing daily-habit step from Phase 5 — running it after the pod-delete is the same operation, just triggered explicitly.

**Proper fix (landed in Phase 7.0.a, 2026-04-30).** Two-track implementation because the OpenBao Helm chart 0.27.2 does not expose `server.startupProbe`:

- **Vanilla Deployments (`helloworld-bff`, `authzen-facade`)** — native `startupProbe` on the main container, reusing the existing readiness path:
  ```yaml
  startupProbe:
    httpGet:
      path: /ready    # /readyz for authzen-facade
      port: http
    failureThreshold: 30        # 30 × 10s = 5 minutes of grace
    periodSeconds: 10
  livenessProbe:
    # …existing liveness probe; only kicks in once startupProbe succeeds…
  ```
  HTTP-probe over socket-exec because the readiness path proves the SPIFFE mount AND the app's HTTP server are both up — single check covers both. Files: `apps/helloworld-bff/deploy/02-deployment.yaml`, `apps/authzen-facade/deploy/02-deployment.yaml`.

- **OpenBao StatefulSets (`openbao-0/1/2`, `openbao-seal-0`)** — chart-constrained, no server-level `startupProbe`. Used `server.extraInitContainers` instead: an init container that polls `/spiffe-workload-api/spire-agent.sock` for up to 5 minutes (30×10s, matching the same grace window) before letting the chart's main containers start. Same defensive intent, different mechanism. Files: `infrastructure/openbao/03-openbao-seal-values.yaml`, `infrastructure/openbao/04-openbao-values.yaml`.

For every future SPIFFE-CSI consumer, prefer the native `startupProbe` shape; fall back to `extraInitContainers` only when the workload is chart-managed and the chart lacks `startupProbe` exposure.

**Defense-in-depth alternative** (already covered for chart-constrained workloads above; still applies for OpenBao on top of the init container):
- Apply a high-value `PriorityClass` to SPIRE server, agent, and `spiffe-csi-driver` so they schedule before workload pods at boot. Doesn't *eliminate* the race (workloads can still start before SPIRE finishes attesting), just shrinks the window.

**Verification target after the fix lands.** Reboot Docker Desktop seven times across a week. Zero `kubectl delete pod` interventions required, every workload reaches Ready within 5 min of cluster boot. Track in Phase 7 metrics — Promtail should ingest mount-failure events and alert if any SPIFFE-CSI mount takes longer than the startupProbe budget.

---

## Recovering from a corrupted spire-server datastore

If the SQLite datastore is corrupted (extremely rare), follow the recipe in [spire-ca-rotation.md § Recovery](./spire-ca-rotation.md#recovery-i-deleted-the-upstream-ca-secret-by-mistake) — same procedure: wipe the PVC, restart, re-mint everything from the upstream CA.

```bash
kubectl scale statefulset -n spire spire-server --replicas=0
kubectl delete pvc -n spire spire-data-spire-server-0
kubectl scale statefulset -n spire spire-server --replicas=1
```

The controller-manager will re-create all `ClusterSPIFFEID` registrations within a minute. Workloads will re-attest on next SVID rotation.
