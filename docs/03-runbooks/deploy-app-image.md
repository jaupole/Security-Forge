# Runbook: deploy a first-party app image

> **Always deploy by `@sha256:` digest, never by tag.** A tag ref is denied at
> admission by the `verify-image-signature-secforge` Kyverno policy (Enforce)
> with a confusing message — see [Why](#why-by-digest) below.

There is no GitOps controller (no Argo/Flux). Since 2026-06-11 deploys are
**one command** through the `deploy-app` workflow — git is the source of
truth and the digest bump + apply happen atomically, so declared state ==
live by construction.

## Procedure (standard)

1. **Merge/push** to the app repo's default branch. Every app repo's
   image-build workflow is a thin caller of the fleet-shared
   `Security-Forge/.github/workflows/reusable-image-build.yml`
   (build → push → optional Trivy gate → cosign v2 sign → verify).

2. **Run the deploy command printed in the build's job summary** — copy/paste,
   digest already filled in:
   ```sh
   gh workflow run deploy-app.yml -R jaupole/Security-Forge \
     -f app=<app> -f digest=sha256:<64hex>
   ```
   (`app` ∈ control, portal, member-hub, proposal-forge, business-manager,
   project-manager, document-render — or use the Run-workflow button in the
   Security-Forge Actions UI.)

   The workflow: validates the digest → bumps EVERY manifest pinning that
   app's image (deployment + migration job + cronjobs, so cron digests can't
   drift) → commits + pushes `deploy(<app>): bump to … [skip ci]` → runs
   `sudo secforge-app-deploy <app>` on the box, which git-pulls the ops clone
   and executes `platform/lib/deploy-app.sh`: delete stale one-shot migration
   Job (#36 handled automatically) → apply + wait for migration → apply the
   rest → `kubectl rollout status` per Deployment (readiness probes are the
   smoke test).

   **On failure** the pipeline self-heals: `deploy-app.sh` does
   `kubectl rollout undo`, and the workflow reverts the digest-bump commit —
   git and cluster stay in agreement.

   **Trust model:** the runner account holds no kubeconfig and no cluster
   credential. Its single privilege is the sudoers-ENUMERATED
   `/usr/local/sbin/secforge-app-deploy <app>` wrapper, so a compromised
   workflow can only deploy what main says for an allowlisted app — it cannot
   apply arbitrary manifests or reach kubectl. No long-lived cluster
   credential exists anywhere in the path (bright-line rule).

## Procedure (manual fallback)

The pre-2026-06-11 flow still works when Actions is unavailable: bump the
digests in `platform/manifests/<app>/`, commit + push, then on the box
`sudo bash platform/lib/deploy-app.sh <app>` (it contains the full per-app
mapping) — or the raw `apply-manifest.sh` + `kubectl rollout status` steps it
wraps. Never `kubectl set image` without the matching manifest bump.

> Keyless identity note: because signing now happens inside the reusable
> workflow, every fleet image's certificate identity is
> `https://github.com/jaupole/Security-Forge/.github/workflows/reusable-image-build.yml@…`
> (Fulcio SAN = job_workflow_ref), not the app repo. Kyverno's
> `(secforge|jaupole)` subject regex still matches; tightening the policy to
> exactly this identity is a tracked hardening option.

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

## Signature format contract (cosign v2 pin)

A **digest** ref can ALSO be denied with `no signatures found` — that means the
image was signed in the wrong **format**, not that signing was skipped
(discovered 2026-06-11; operator-backlog #90):

- Kyverno (1.18, incl. current main) only finds cosign **v2 legacy
  signatures** — the `sha256-<digest>.sig` tag. cosign **v3** signs in the
  sigstore bundle format via OCI referrers; on GHCR (no native referrers API)
  the bundle lands under a tag-fallback index whose entry **loses the bundle
  artifactType**, so Kyverno's `SigstoreBundle` discovery skips it too. A
  v3-signed image is unverifiable on this cluster in *any* policy mode, even
  though CI's own `cosign verify` passes.
- Therefore every image-build workflow (all 6 app repos + gotenberg +
  keycloak) pins the cosign **binary** via the installer input
  `cosign-release: 'v2.6.3'` while leaving the `cosign-installer` **action**
  current. Bots (dependabot/Renovate) bump the action SHA but never
  `with:`-inputs, so the pin survives routine bumps — the 2026-06-11 breakage
  was dependabot bumping the action to v4 (cosign v3 default) in
  ecosystem-control. **Keep the input pin when copying the workflow to a new
  app repo.**
- Quick diagnostic for a denied digest — does the legacy signature exist?
  ```sh
  cosign tree ghcr.io/jaupole/<app>@sha256:<digest>   # or:
  # 200 = signed correctly; 404 = wrong format / unsigned → rebuild after
  # checking the workflow still passes cosign-release v2.x
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    "https://ghcr.io/v2/jaupole/<app>/manifests/sha256-<digest>.sig"
  ```
- Exit criteria for dropping the pin (re-test ~quarterly) live in
  operator-backlog **#90**. Do not migrate the policy to
  `type: SigstoreBundle` before a dual-sign transition — running images carry
  only legacy signatures and would fail re-admission on restart.

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
