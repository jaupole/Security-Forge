# Image supply-chain verification — gap analysis & closure plan

> Status: living reference. Last surveyed **2026-07-05** (cosign verify/tree over
> every image running in-cluster). Supersedes the ad-hoc note in operator-backlog
> **#41**. Companion to `platform/manifests/kyverno/policies/05-image-signature-verification.yaml`.

## TL;DR

Two independent supply-chain controls apply to container images: **where they come
from** (registry allowlist), **that they are immutable** (digest pin), and **that
they are authentic** (cosign signature). Current state:

| Control | Policy | State | Gap |
|---|---|---|---|
| Registry allowlist | `restrict-image-registries` | **Enforce** | none |
| Digest pinning | `require-image-digest` | **Audit** | **54 of ~81 running images are tag-only (unpinned)** |
| Signature — SecForge images | `verify-image-signature-secforge` | **Enforce** (→ fail-closed, PR #95) | none |
| Signature — vendor images | `verify-image-signature-vendors` | Audit → **Enforce T1+T2** (PR #96) | ~44 vendor repos are unsigned |

The signature story is a **minority-signed** reality: of 65 vendor repos, only ~16
carry a verifiable cosign signature. The other ~44 are unsigned or mirror-stripped —
for those, **digest pinning is the primary realistic control, and it is not
currently enforced.** Closing the gap is therefore *two* workstreams: enforce
signatures on the signed subset (done, PR #96), and get every image digest-pinned
so `require-image-digest` can go Enforce.

## Vendor signing survey (65 repos, by how the vendor signs)

| Tier | How it verifies | Repos | Disposition |
|---|---|---|---|
| **T1** | keyless cosign signature (Fulcio/Rekor) | spiffe `spire-*`+`spiffe-csi-driver`, `otel/opentelemetry-collector-contrib`, `aquasec/trivy-operator`, `cgr.dev/chainguard/*`, `jetstack/trust-manager`+`trust-pkg-*`, `registry.k8s.io/*` (Google OIDC) | **Enforced** — PR #96 |
| **T2** | static cosign key (SHA-512, no Rekor) | cert-manager core: `controller`/`webhook`/`cainjector`/`acmesolver`/`ctl`/`startupapicheck` | **Enforced** — PR #96 (`keys` attestor, published pubkey) |
| **T3** | SLSA attestation only, **no `.sig`** | `cloudnative-pg/cloudnative-pg` (operator), `kyverno/*` | **Deferred** — needs `attestations:` verify; attestation signer identity not yet cleanly keyless-verifiable (investigate predicate + signer) |
| **T4** | **unsigned / mirror-stripped** | ~44 repos (see appendix) | **No signature exists** — close via digest-pin (baseline) + mirror-and-sign (crown jewels) |

Identities are recorded inline in the policy rules. Note two non-GitHub signers:
`registry.k8s.io` → `krel-trust@k8s-releng-prod.iam.gserviceaccount.com` /
`accounts.google.com`; cert-manager core → static key, not keyless.

## The two structural gaps

### Gap A — the unsigned majority (~44 repos)
Includes crown-jewel dependencies: **CloudNativePG data plane** (`postgresql`,
`plugin-barman-cloud[-sidecar]` — your databases + backups), **Istio**
(`registry.istio.io/release/*` — unsigned on that registry), **OpenBao**, plus the
long tail (grafana/*, quay.io/prometheus*, velero, wazuh, authzed, topolvm,
minio, keycloak-operator, rancher/k3s, kube-rbac-proxy) and **every** `mirror.gcr.io/*`
and `public.ecr.aws/*` image (mirrors strip upstream signatures). Also the unsigned
members of otherwise-signed orgs: `spiffe-helper`, `spire-controller-manager`.

No cosign signature is published, so no `verifyImages` rule can verify them.

### Gap B — digest pinning is Audit, and 54 images are unpinned
`require-image-digest` runs in **Audit** and excludes `kube-system`, `kube-public`,
`kube-node-lease`, `kyverno`, `topolvm-system`, `trivy-system`. 54 unique running
images use a mutable **tag** (e.g. `openbao:2.5.4`, `cloudnative-pg/postgresql:17.6-bookworm`,
`grafana:13.0.1-security-01`, `spire-server:1.14.5`). A mutable tag means the registry
can serve a *different* image for the same tag on the next pull/reschedule. For the
Gap-A unsigned images, **this is the control that matters** — and it is not enforced.

## Closure strategy

1. **Signed subset (T1 + T2) → Enforce.** ✅ PR #96. A future unsigned/tampered digest
   of any signed vendor now denies at admission (and pages via
   `ImageSignatureVerificationFailing`).

2. **T3 attestation verify.** Add `attestations:`-based verification for the
   CloudNativePG operator and Kyverno once the attestation predicate + signer
   identity are pinned down. Medium effort, 2 image families.

3. **Gap B — digest-pin everything, then enforce (recommended baseline, universal).**
   This is the highest-leverage move for the unsigned majority.
   - Pin all 54 tag-only images to `@sha256:` digests in their manifests/helm values.
     Current digests are available with zero registry calls from the running pods'
     `status.containerStatuses[].imageID`.
   - Narrow the `require-image-digest` namespace exclusions (only genuinely
     unmanageable ones — e.g. k3s-bundled in `kube-system` — stay excluded).
   - Flip `require-image-digest` **Audit → Enforce**. Combined with the enforced
     registry allowlist and GitOps review, this gives immutability for images we
     cannot cryptographically verify. **Do the pinning first — flipping to Enforce
     against 54 unpinned images would block admission.**

4. **Gap A crown jewels — mirror-and-sign.** For the dependencies whose integrity
   matters most and which are unsigned upstream:
   - **CloudNativePG** data plane (`postgresql`, barman), **Istio** data/control
     plane, **OpenBao**, and optionally the unsigned SPIRE bits.
   - Pipeline: pull upstream digest → push to `ghcr.io/secforge/<mirror>/…` → cosign
     **keyless sign** in CI (same identity as our own images) → deploy from the
     mirror. The **existing** `verify-image-signature-secforge` enforce policy then
     covers them for free.
   - Cost: a mirror+sign CI workflow + Renovate wiring for updates + re-pointing
     those workloads' image references. Real work; highest provenance.

5. **Gap A long tail — accept digest-pin only.** grafana/*, prometheus/*, velero,
   wazuh, rancher/k3s, minio, kube-rbac-proxy, all mirrors. Mirroring+signing all of
   these is not worth the maintenance; digest-pin (step 3) + registry allowlist is the
   proportionate control. Revisit per-image if a vendor starts signing.

## Prioritized roadmap

1. **Merge PR #96** (signed subset enforce, T1+T2). *Immediate, low risk.*
2. **Digest-pin sweep** → flip `require-image-digest` to Enforce. *Biggest coverage
   gain for the unsigned majority; medium effort, staged (pin → verify → enforce).*
3. **Mirror-and-sign crown jewels** (CNPG data, Istio, OpenBao). *High provenance,
   high effort; own project.*
4. **T3 attestation verify** (CNPG operator, Kyverno). *Nice-to-have.*

## Appendix

### T4 unsigned / mirror-stripped repos (as deployed, 2026-07-05)
`ghcr.io/cloudnative-pg/{postgresql,plugin-barman-cloud,plugin-barman-cloud-sidecar}`,
`ghcr.io/spiffe/{spiffe-helper,spire-controller-manager}`,
`ghcr.io/authzed/{spicedb,spicedb-operator}`, `ghcr.io/topolvm/topolvm-with-sidecar`,
`docker.io/openbao/openbao`, `docker.io/grafana/{grafana,loki,loki-canary,promtail,tempo}`,
`docker.io/{kiwigrid/k8s-sidecar,hashicorp/vault-secrets-operator}`,
`docker.io/velero/{velero,velero-plugin-for-aws}`, `docker.io/wazuh/*`,
`quay.io/prometheus/{prometheus,alertmanager,node-exporter}`,
`quay.io/prometheus-operator/{prometheus-operator,prometheus-config-reloader}`,
`quay.io/{brancz/kube-rbac-proxy,minio/minio,keycloak/keycloak-operator,kiwigrid/k8s-sidecar}`,
`rancher/{local-path-provisioner,mirrored-coredns-coredns,mirrored-metrics-server}`,
`registry.istio.io/release/{pilot,proxyv2,ztunnel,install-cni}`,
all `mirror.gcr.io/*` (python, busybox, alpine/k8s, aquasec/trivy),
`public.ecr.aws/docker/library/busybox`.

### `require-image-digest` current exclusions
`kube-system`, `kube-public`, `kube-node-lease`, `kyverno`, `topolvm-system`, `trivy-system`.

### How to re-run the survey
`cosign` is at `/usr/local/bin/cosign` on the host. Probe scripts:
`cosign tree <ref>` (registry-only: has signature/attestation?) then
`cosign verify <ref> --certificate-identity-regexp='.*' --certificate-oidc-issuer-regexp='.*' -o json`
to read the signer identity. For static-key vendors add `--key <pub> --signature-digest-algorithm sha512 --insecure-ignore-tlog`.
