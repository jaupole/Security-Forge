# Runbook: mirror, deploy, and verify the Gotenberg document-rendering service

Stands up (or upgrades) the shared `document-render` service. See **ADR-0037**
and `platform/manifests/document-render/README.md`.

## 0. Prerequisites

- You can run the `gotenberg-mirror` GitHub Actions workflow (self-hosted
  `secforge` runner online).
- `kubectl` on the box (`ssh secforge`, `sudo -n kubectl`).

## 1. Mirror + sign the image

Run the workflow (GitHub → Actions → **gotenberg-mirror** → Run workflow), with
`version` = the upstream Gotenberg version to ship (e.g. `8.32.0`).

It will: copy `docker.io/gotenberg/gotenberg:<version>` to
`ghcr.io/jaupole/gotenberg:<version>` by digest, Trivy-scan it (fails on a
fixable CRITICAL), cosign-keyless-sign it, and print the signed
`...:<version>@sha256:<digest>` ref in the run summary.

**First run only — make the package public:** GitHub → your packages →
`gotenberg` → Package settings → Change visibility → **Public**. This is why the
deployment needs no imagePullSecret and `document-render` stays secret-free.

## 2. Pin the deployment to the signed digest

Edit `platform/manifests/document-render/09-deployment.yaml`, set the container
`image:` to the ref the workflow printed:

```yaml
  image: ghcr.io/jaupole/gotenberg:8.32.0@sha256:<digest>
```

Commit + push (manifests are not auto-synced).

## 3. Apply the manifests

```bash
cd ~/secforge   # the git checkout on the box; git pull first
sudo -n kubectl apply -f platform/manifests/document-render/01-namespace.yaml
sudo -n kubectl apply -f platform/manifests/document-render/03-serviceaccount.yaml
sudo -n kubectl apply -f platform/manifests/document-render/05-network-policies.yaml
sudo -n kubectl apply -f platform/manifests/document-render/06-authorization-policy.yaml
sudo -n kubectl apply -f platform/manifests/document-render/09-deployment.yaml
sudo -n kubectl apply -f platform/manifests/document-render/10-services.yaml
# PF egress to the renderer:
sudo -n kubectl apply -f platform/manifests/proposal-forge/05-network-policies.yaml
```

Wait for ready:

```bash
sudo -n kubectl -n document-render rollout status deploy/gotenberg
# Confirm the SSRF guards took effect (Gotenberg logs its config at boot):
sudo -n kubectl -n document-render logs deploy/gotenberg | grep -iE 'deny|webhook|timeout' | head
```

## 4. Smoke test from a Proposal Forge pod

The renderer is reachable ONLY from consumer namespaces over the mesh, so test
from inside PF:

```bash
PF=$(sudo -n kubectl -n proposal-forge get pod -l app.kubernetes.io/name=proposal-forge -o name | head -1)

# Health (should be 200):
sudo -n kubectl -n proposal-forge exec "$PF" -- \
  sh -c 'wget -qS -O /dev/null http://gotenberg.document-render.svc.cluster.local:3000/health 2>&1 | head'

# Real conversion (writes /tmp/out.pdf in the PF pod; expect a %PDF header):
sudo -n kubectl -n proposal-forge exec "$PF" -- sh -c '
  printf "<html><body><h1>render check</h1></body></html>" > /tmp/index.html &&
  wget -q -O /tmp/out.pdf --post-file=/tmp/index.html \
    --header="Content-Type: text/html" \
    http://gotenberg.document-render.svc.cluster.local:3000/forms/chromium/convert/html ;
  head -c4 /tmp/out.pdf'
```

> The PF image has Node's `fetch`/`FormData`; for a manual curl-style multipart
> probe prefer the app's own `/api/v1/projects/:id/export/pdf` once `PDF_RENDERER`
> is flipped (step 5). The wget probe above confirms network + authz + a basic
> render.

**If denied / connection reset:** isolate the layer.
- `sudo -n kubectl -n document-render logs ds/ztunnel -n istio-system` style mesh
  logs, or temporarily remove `06-authorization-policy.yaml` to test whether the
  block is L7 (authz principal) vs L3/L4 (NetworkPolicy). Re-apply after.
- Confirm both namespaces are ambient: `kubectl get ns proposal-forge document-render -o jsonpath` for `istio.io/dataplane-mode`.

## 5. Cut Proposal Forge over

Set `PDF_RENDERER=gotenberg` on the PF deployment (and confirm `GOTENBERG_URL`
defaults to the service DNS — it does). Roll PF, then export each scope
(proposal / pricing / combined) from the UI and compare against a pre-cutover
PDF: cover page, headings/colors, pricing tables, header (project name) and
footer ("Page X of Y").

```bash
sudo -n kubectl -n proposal-forge set env deploy/proposal-forge PDF_RENDERER=gotenberg
sudo -n kubectl -n proposal-forge rollout status deploy/proposal-forge
```

To roll back instantly: `set env ... PDF_RENDERER-` (removes it → falls back to
the in-image Puppeteer path).

## 6. Finalize (after parity is confirmed)

Once PF parity is signed off, the Puppeteer/Chromium path is removed and PF goes
distroless (Phase 1b — separate change): drop `puppeteer` from `package.json`,
delete the Puppeteer branch in `pdf-export.service.ts`, and rebase the PF
Dockerfile off the distro-chromium layers. Do NOT do this before step 5 parity.

## Upgrades / CVE refresh

Re-run the `gotenberg-mirror` workflow with the new version, repeat steps 2–4.
The Trivy gate blocks shipping a fixable CRITICAL. One image patched here covers
every consumer.
