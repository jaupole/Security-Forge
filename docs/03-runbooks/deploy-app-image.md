# Runbook: deploy a first-party app image (control / portal / member-hub)

> **Always deploy by `@sha256:` digest, never by tag.** A tag ref is denied at
> admission by the `verify-image-signature-secforge` Kyverno policy (Enforce)
> with a confusing message — see [Why](#why-by-digest) below.

There is no GitOps controller (no Argo/Flux). App image bumps are a **manual
`kubectl set image` by digest, plus a matching digest bump in the
Security-Forge manifest** so a future `kubectl apply` doesn't revert prod.

## Procedure

1. **Merge** the app PR (`ecosystem-control`, `ecosystem-portal`, or `member-hub`).
   The push-to-default-branch image-build workflow builds, **cosign-signs the
   digest**, and pushes to `ghcr.io/jaupole/<app>`.

2. **Get the digest** from the build's job summary (the "Built + signed" step
   prints `…/<app>@sha256:<digest>`), or from the run log:
   ```sh
   gh run view <run-id> -R jaupole/<repo> --log | grep -oE '<app>@sha256:[a-f0-9]{64}' | head -1
   ```

3. **Deploy by digest** (NOT by tag):
   ```sh
   # control api
   kubectl set image deploy/control -n control api=ghcr.io/jaupole/control@sha256:<digest>
   # portal (static nginx; runs in the `control` namespace)
   kubectl set image deploy/portal  -n control nginx=ghcr.io/jaupole/portal@sha256:<digest>
   # member-hub api
   kubectl set image deploy/member-hub -n member-hub api=ghcr.io/jaupole/member-hub@sha256:<digest>
   kubectl rollout status deploy/<name> -n <ns> --timeout=150s
   ```
   Any CronJobs that share the app image (e.g. `control` namespace's
   `billing-usage-sync`, `signup-cleanup`, audit cronjobs in `member-hub`)
   are bumped the same way — `kubectl set image cronjob/<name> <container>=…@sha256:<digest>`.

4. **Bump the Security-Forge manifest digest in the same change** so declared
   state == live (otherwise `kubectl apply` reverts the deploy):
   - control: `platform/manifests/control/09-backend-deployment.yaml` **and**
     `08-migration-job.yaml` (paired); `10-portal-deployment.yaml` for portal;
     the cron manifests (`12`, `15`) if their image moved.
   - member-hub: `platform/manifests/member-hub/09-backend-deployment.yaml`,
     `08-migration-job.yaml`, and the audit cronjobs (`12`, `13`).
   Open a `chore(deploy): …` PR.

   > The migration Job is a fixed-name one-shot; re-`apply`ing a bumped
   > `08-migration-job.yaml` needs the prior Job deleted first (Security-Forge#36).

## Why by digest

`verify-image-signature-secforge` (ClusterPolicy, **Enforce**, cluster-wide)
verifies a cosign **keyless** signature for every `ghcr.io/{secforge,jaupole}/*`
image (`mutateDigest:false`, `verifyDigest:false`). CI signs **by digest**
(`cosign sign …@${DIGEST}`), so the signature artifact is keyed on the content
digest:

- a **`@sha256:` ref** points straight at the signed object → **verifies, admits**;
- a **tag ref** must first be resolved to a digest, and only verifies if that tag
  resolves to a CI-signed digest. With buildx provenance/SBOM attestations a tag
  can resolve to an index/sub-manifest that wasn't separately signed → cosign
  returns *"no signatures found"* → admission is **denied** with:
  ```
  verify-image-signature-secforge: autogen-verify-secforge: unverified image ghcr.io/jaupole/<app>:<tag>
  ```
  That error means **"deploy by digest"**, not "the image is bad."

This is the intended supply-chain contract — the in-repo manifests are already
100% `@sha256`-pinned.

### Note on `require-image-digest`

A second policy, `require-image-digest`, would reject **any** tag ref by format
with a clearer message — but it ships in **Audit** (non-blocking) because the
cluster still runs ~40 tag-pinned **vendor/operator** images (cnpg, istio,
cert-manager, grafana/prometheus/loki, openbao, spicedb, spire, …). Flip it to
**Enforce only after** Renovate's digest-pin cadence (see
[base-image-cve-cadence.md](./base-image-cve-cadence.md)) has pinned those —
otherwise Enforce blocks legitimate vendor redeploys. Until then,
`verify-image-signature-secforge` is the effective digest-forcing gate for
first-party apps.
