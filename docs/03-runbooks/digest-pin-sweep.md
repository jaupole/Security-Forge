# Runbook — digest-pin sweep + enforce `require-image-digest`

> Goal: pin every managed vendor image to an immutable `@sha256:` digest, then flip
> `require-image-digest` from **Audit → Enforce**. This is the Gap-B closure from
> `docs/04-security/image-supply-chain-verification.md`. It is **staged and
> per-component** — do NOT flip to Enforce until every managed workload is pinned,
> or admission will block.
>
> Policy file: `platform/manifests/kyverno/policies/09-require-image-digest.yaml`
> (currently `validationFailureAction: Audit`; excludes `kube-system`, `kube-public`,
> `kube-node-lease`, `kyverno`, `topolvm-system`, `trivy-system`).
>
> Signature status per image is in the companion doc's survey. Images marked
> **[sig-enforced]** below are already covered by PR #96 (belt-and-suspenders to pin);
> images marked **[unsigned]** are where digest-pinning is the *only* integrity
> control — prioritise those.

## 0. Prerequisites

- `ssh secforge` with `sudo -n kubectl` (read + apply per deploy policy).
- Work on the repo source of truth `/home/ops/secforge`; land changes as a PR
  (`envsubst`-then-`kubectl apply` / `helm upgrade` on merge). No live ad-hoc patch.
- **Regenerate fresh digests at execution time** (do not trust the 2026-07-05 table
  below — upstream tags may have moved):

```bash
ssh secforge 'sudo -n kubectl get pods -A -o json' | python3 -c '
import sys,json
d=json.load(sys.stdin); m={}
for p in d["items"]:
    st=p.get("status",{})
    for cs in (st.get("containerStatuses") or [])+(st.get("initContainerStatuses") or []):
        im=cs.get("image",""); iid=cs.get("imageID","")
        if "@sha256:" in im or "@sha256:" not in iid: continue
        m.setdefault(im.split("@")[0], iid.split("@")[1])
for k in sorted(m): print(f"{k}\t{m[k]}")
'
```

## 1. Per-component procedure (repeat for each row in §3)

For **each** component, one at a time:

1. Get the current digest for its image(s) (command above).
2. Edit the file in §3 to pin the image by digest, using that chart's digest field
   (see "method"). **Verify the exact key against the chart's `values.yaml` schema** —
   field names differ per chart (`image.digest`, `image.sha`, or a full `@sha256:` ref).
3. Apply just that component (`helm upgrade …` via its `platform/components/*.sh`, or
   `kubectl apply -f <manifest>` for raw manifests).
4. **Verify** the workload rolled and is pinned + healthy:
   ```bash
   ssh secforge 'sudo -n kubectl get pods -n <ns> -o jsonpath="{range .items[*]}{.metadata.name}{\"  \"}{.spec.containers[*].image}{\"\n\"}{end}"'
   # every image must show @sha256:; pods Ready; no restarts
   ssh secforge 'sudo -n kubectl get events -n <ns> --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail'
   ```
5. Only then move to the next component. **Rollback** = revert that one edit + re-apply.

## 2. Order of work (safest first)

1. **Raw-manifest jobs/operators** (§3a) — direct edits, no chart, lowest risk.
2. **Single-image Helm charts** (§3b) — otel, velero, openbao, trust-manager, VSO.
3. **Multi-image charts** (§3c) — loki, kube-prometheus-stack, spire, cert-manager, istio.
4. **CNPG operator CRs** (§3d) — the Postgres data plane; pin in each `Cluster` CR
   (the operator re-asserts `imageName`, so it MUST be pinned in the CR, not mutated).
5. **§4 flip to Enforce** — only after §3 is 100% done and verified.

## 3. Pin targets (digests as of 2026-07-05 — regenerate before use)

### 3a. Raw manifests (direct edit)
| Image | Digest | File |
|---|---|---|
| openbao:2.5.4 **[unsigned]** | `sha256:436eaf9778cad75507ff70ea26ace30dcbe15606e619ac3823495663d7f7c115` | `platform/manifests/openbao/14-openbao-raft-snapshot.yaml` |
| mirror.gcr.io/library/python:3.13-slim **[unsigned]** | `sha256:b04b5d7233d2ad9c379e22ea8927cd1378cd15c60d4ef876c065b25ea8fb3bf3` | `platform/manifests/openbao/12-platform-audit-anchor.yaml`, `…/13-platform-audit-verifier.yaml`, `platform/manifests/observability/22-loki-audit-verifier.yaml` (+ ct-monitor / audit jobs) |
| cgr.dev/chainguard/kubectl **[sig-enforced]** | `sha256:6b7bd52501052b5072eb108becf43f8fa3a0e06da21fb8e605f0aed9de1a1d0f` | `platform/manifests/vault-secrets-operator/05-watchdog-cronjob.yaml` |
| busybox:1.36 **[unsigned]** | `sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662` | `platform/manifests/vault-secrets-operator/05-watchdog-cronjob.yaml` |
| authzed/spicedb-operator **[unsigned]** | `sha256:6049e4f4bbb8e3374b3f76188577304e48452c5f6a4b5a9b4f8902613aa39bf6` | `platform/manifests/spicedb/operator/bundle.yaml` |
| authzed/spicedb **[unsigned]** | `sha256:93f9e1216fe90999c3cf05769720d3333adb39278552775439a224d2ab041034` | SpiceDBCluster CR (`platform/manifests/spicedb/…`) — `spec.image` |
| keycloak-operator:26.3.3 **[unsigned]** | `sha256:e949939f50db37cca8d719bfb8854b4b694813972211c2fc84a21e6ac473f486` | `platform/manifests/keycloak/operator/operator.yaml` |

### 3b. Single-image Helm charts (`platform/values/<file>` + `platform/components/*.sh`)
| Image | Digest | Values file · method |
|---|---|---|
| otel/opentelemetry-collector-contrib:0.153.0 **[sig-enforced]** | `sha256:93aad750175cbf1a973ae1c5886c3371f4d800f61be25cdd26870b8441ffe9fa` | `otel-collector.yaml` · `image.digest` (opentelemetry-collector chart) |
| velero/velero:v1.18.0 **[unsigned]** + velero-plugin-for-aws | `sha256:e4d1e79be2ee1d51056734ada5e51c78a29b924e4d055cd28e0b4103ae2268ad` (plugin already `@sha256` pinned) | `velero.yaml` · `image.tag`/`image.digest`; initContainers plugin already pinned |
| openbao/openbao:2.5.4 **[unsigned]** | `sha256:436eaf9778cad75507ff70ea26ace30dcbe15606e619ac3823495663d7f7c115` | `openbao.yaml` (+ `openbao-seal.yaml`) · `server.image` — verify chart supports digest; may need full `@sha256:` ref |
| jetstack/trust-manager:v0.22.1 **[sig-enforced]** + trust-pkg | `sha256:23e2ab0711d77c3d25a7297d480883e8d037659db88dcdc0dab788a08a1b2097` (pkg `sha256:06fe54a72d1ddb268d64a022d0d9f031aa93204136a8e9a131913fc968a3889d`) | `trust-manager.yaml` · `image.digest` + `defaultPackageImage.digest` |
| hashicorp/vault-secrets-operator:1.4.0 **[unsigned]** + kube-rbac-proxy | `sha256:e18b1859f17a17a4bb7786d5cf8e0691dc4b8cb03c8a025c99ddc33e908c2587` (rbac-proxy `sha256:e6a323504999b2a4d2a6bf94f8580a050378eba0900fd31335cf9df5787d9a9b`) | `vault-secrets-operator.yaml` · `controller.manager.image` + `controller.kubeRbacProxy.image` |
| trivy-operator:0.31.1 **[sig-enforced]** | `sha256:e92ccec7da505ade0df6423fdae1396d1339837b33e091efb0f15e6ddf0e79b0` | `trivy-operator.yaml` — **but `trivy-system` is excluded from the policy**; pin optional |

### 3c. Multi-image Helm charts
| Chart / file | Images + digests | Method (verify field names) |
|---|---|---|
| **loki** `loki.yaml` | grafana/loki:3.6.7 `sha256:3c8fd3570dd9219951a60d3f919c7f31923d10baee578b77bc26c4a0b32d092d`; loki-canary:3.6.7 `sha256:0dac7d5cb383adb8d3723676a70ed0c65b582e636846f4ce48703556dd509ad1`; kiwigrid/k8s-sidecar `sha256:a6b3f707…` (2.5.0) | `loki.image.digest`, `monitoring.lokiCanary.image.digest`, `sidecar.image.digest` |
| **tempo** `tempo.yaml` | grafana/tempo:2.9.0 `sha256:65a5789759435f1ef696f1953258b9bbdb18eb571d5ce711ff812d2e128288a4` | `tempo.image.digest` |
| **promtail** `promtail.yaml` | grafana/promtail:3.5.1 `sha256:65bfae480b572854180c78f7dc567a4ad2ba548b0c410e696baa1e0fa6381299` | `image.digest` |
| **kube-prometheus-stack** `kube-prometheus-stack.yaml` | grafana:13.0.1-security-01 `sha256:2d1f9ae6…`; prometheus:v3.11.3 `sha256:c0b857aead0d5793aa566adb8f49a9983d6f6031652098759d521a330cfa050f`; alertmanager:v0.32.0 `sha256:58e117ea…`; prometheus-operator:v0.90.1 `sha256:52a6a92d…`; config-reloader:v0.90.1 `sha256:693faa0b…`; node-exporter:v1.11.1 `sha256:0f422f62…`; kube-state-metrics:v2.18.0 **[sig-enforced]** `sha256:1545919b…` | `grafana.image.sha`, `prometheus.prometheusSpec.image.sha`, `alertmanager.alertmanagerSpec.image.sha`, `prometheusOperator.image.sha`, `prometheusOperator.prometheusConfigReloader.image.sha`, `prometheus-node-exporter.image.digest`, `kube-state-metrics.image.digest` |
| **spire** `spire.yaml` | spire-server:1.14.5 **[sig-enforced]** `sha256:295af372…`; spire-agent:1.14.5 **[sig-enforced]** `sha256:efb8d29a…`; spiffe-csi-driver:0.2.7 **[sig-enforced]** `sha256:9dfe4f0c…`; oidc-discovery-provider:1.14.5 **[sig-enforced]** `sha256:55370428…`; spiffe-helper:0.11.0 **[unsigned]** `sha256:1c92e599…`; spire-controller-manager:0.6.4 **[unsigned]** `sha256:f8fd8e66…` | per-component `<comp>.image.tag`/`.digest` — verify spiffe chart schema. NB spiffe-helper is a sidecar in **control/member-hub** deploys (`platform/manifests/{control,member-hub}/09-backend-deployment.yaml`) — pin there too |
| **cert-manager** `cert-manager.yaml` (`components/00b-cert-manager.sh`) | controller:v1.20.2 **[sig-enforced]** `sha256:fe0623d7…`; webhook `sha256:baf65112…`; cainjector `sha256:6f5a6441…` | `image.digest`, `webhook.image.digest`, `cainjector.image.digest`, `acmesolver.image.digest`, `startupapicheck.image.digest` |
| **istio** `istio-istiod.yaml`,`istio-cni.yaml`,`istio-ztunnel.yaml` | pilot:1.30.0-distroless `sha256:09f24385…`; proxyv2 `sha256:65092fef…`; ztunnel:1.30.0 `sha256:617fd52f…`; install-cni `sha256:24a64232…` **(all [unsigned])** | istiod: `pilot.image` (full `@sha256:` ref) + `global.proxy.image`; cni: `.image`; ztunnel: `.image`. Istio uses hub/tag — set full digest ref |
| **wazuh** `platform/manifests/wazuh/vendor-chart/values.yaml` | indexer/dashboard/manager 4.14.5 (several already `@sha256` pinned — confirm) **[unsigned]** | pin any tag-only entries in the vendor-chart values |

### 3d. CNPG Postgres data plane (operator CRs) **[unsigned — high priority]**
Pin `spec.imageName` in **every** `Cluster` CR to the digest:
- Files: `platform/manifests/{control,member-hub,keycloak,project-manager,proposal-forge,business-manager,spicedb}/02-cnpg-cluster.yaml`
- `postgresql:17.6-bookworm` → `ghcr.io/cloudnative-pg/postgresql:17.6-bookworm@sha256:f785551be35036d65a0f1ebe71995022d261a829391fc2f14222ca19795d7c20`
- Barman plugin (`plugin-barman-cloud` `sha256:0b9c4281…`, `plugin-barman-cloud-sidecar` `sha256:578926fb…`) — pinned where the plugin is installed (`platform/components/09h-cnpg-barman-plugin.sh` / plugin manifest).
- CNPG **operator** image (`cloudnative-pg:1.29.1`) — `platform/values/cloudnativepg.yaml` · `image.digest`.

## 4. Flip `require-image-digest` to Enforce (LAST — only after §3 verified)

1. Confirm **zero** tag-only images remain in non-excluded namespaces:
   ```bash
   ssh secforge 'sudo -n kubectl get pods -A -o json' | python3 -c '
   import sys,json
   ex={"kube-system","kube-public","kube-node-lease","kyverno","topolvm-system","trivy-system"}
   d=json.load(sys.stdin); bad=set()
   for p in d["items"]:
       ns=p["metadata"]["namespace"]
       if ns in ex: continue
       for c in (p["spec"].get("containers") or [])+(p["spec"].get("initContainers") or []):
           if "@sha256:" not in c.get("image",""): bad.add(ns+"  "+c["image"])
   print("UNPINNED REMAINING:", len(bad)); [print(" ",x) for x in sorted(bad)]
   '
   ```
2. When that prints `UNPINNED REMAINING: 0`, edit
   `platform/manifests/kyverno/policies/09-require-image-digest.yaml`:
   `validationFailureAction: Audit` → `Enforce`. Keep the current namespace exclusions
   (k3s-bundled `kube-system`, self-managed `kyverno`/`topolvm-system`/`trivy-system`).
   Consider `webhookConfiguration.failurePolicy: Fail` to match the signature policies
   (same HA/exclusion safety basis).
3. Validate then apply:
   ```bash
   kubectl apply --dry-run=server -f platform/manifests/kyverno/policies/09-require-image-digest.yaml
   kubectl apply -f platform/manifests/kyverno/policies/09-require-image-digest.yaml
   ```
4. Smoke test: delete one pod in a non-excluded ns and confirm it re-admits.
   **Rollback:** set back to `Audit` and re-apply.

## 5. Done criteria
- `UNPINNED REMAINING: 0` in non-excluded namespaces.
- `require-image-digest` = `Enforce`, cluster healthy, no `PolicyViolation` events.
- Update `docs/04-security/image-supply-chain-verification.md` (Gap B → closed) and
  operator-backlog #41.
