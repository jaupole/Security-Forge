# Platform chart roll

How to roll a Helm chart (or a pinned image inside one) on secforge-prod, and
the one rule that is easy to forget.

## The rule: RBAC change ⇒ rollout restart

Helm only restarts a workload when its pod template changes. A chart roll that
changes RBAC (ClusterRole / Role / bindings) but not the template leaves the
**old pod running on old permissions** until its next unplanned restart.

That is how Vault Secrets Operator broke: the 2026-10-13 roll to chart 1.6.0
dropped the HCP rules from the manager ClusterRole while the image stayed
pinned at 1.4.0. The running pod was untouched, so nothing noticed. Seventeen
days later the k3s-upgrade mount storm restarted it and it crash-looped on
startup ("failed to wait for vaultconnection caches to sync") in the middle
of an incident.

`platform/lib/install-helm.sh` now enforces the rule: it snapshots the
release's RBAC resourceVersions and workload pod-template hashes before
`helm upgrade`, and afterwards rollout-restarts every release workload whose
template did not change if any RBAC object did. Set `HELM_RBAC_ROLL_GUARD=0`
only for first-boot bootstrap where nothing is running yet.

Corollary for values files: keep a chart's pinned **image** at the chart's
`appVersion`. A chart/image split (chart 1.6.0, image 1.4.0) means the RBAC
and CRDs come from one version and the binary from another.

## Procedure (ops user on the box)

```bash
ssh secforge
cd ~/secforge && git pull --ff-only
export KUBECONFIG=/home/ops/.kube/config   # root's helm has NO kubeconfig
helm repo update                           # stale index ⇒ "not found in index"
```

1. **CRDs first** when the chart version changes. Helm never upgrades a
   chart's `crds/`. Pre-apply them:
   `helm pull <repo/chart> --version X --untar -d /tmp/chart &&
   kubectl apply --server-side --force-conflicts -f /tmp/chart/<chart>/crds/`
   (VSO: `crds/`; kube-prometheus-stack: `charts/crds/crds/`).
2. **Roll** via the component script's `install-helm.sh` call (copy the exact
   `--release/--namespace/--chart/--version/--values` from
   `platform/components/<nn>-<component>-install.sh`). Watch the
   `>>> RBAC changed in this roll` / `rollout restart` lines.
3. **Verify** the workload is on the new image and healthy, then
   `sudo systemctl start k8s-drift-check` and confirm
   `helm_drifted=0 helm_manifest_drifted=0`.
4. **Commit** any values change from Windows first (the box deploy key is
   read-only); the box must be at the commit you rolled.

Gotchas that bit before: `07e-prometheus`, `07f-loki`, `09a-velero` are
root-token gated even though the gate is bootstrap-only (run their
`install-helm.sh` line directly); otel-collector ≥ 0.159 rejects
`service.telemetry.metrics.address`; Kyverno 3.9 dry-run admission adds a
`kyverno.io/verify-images-scoped` annotation that the drift script ignores.
