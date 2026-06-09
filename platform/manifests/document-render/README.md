# document-render (Gotenberg)

A single, shared, **stateless** document-rendering service for the ecosystem.
It converts **HTML→PDF** (Chromium), **Office→PDF** (LibreOffice), and **merges
PDFs**, behind a REST API on `:3000`. It replaces the per-app headless-Chromium
that Proposal Forge (and soon Project Tracker) would otherwise each ship in
their own image.

See **ADR-0037** for the decision and **docs/03-runbooks/gotenberg-build-and-deploy.md**
for the operational procedure.

## Why this exists

- **One image to CVE-patch, not N.** Chromium + LibreOffice drag a large
  dependency closure. Carrying it once here lets the consuming apps go
  lean/distroless and removes their Trivy-scan burden.
- **No drift.** Apps build their document as HTML once and convert it here,
  instead of maintaining a parallel renderer per output format.
- **Reusable.** Any future app that needs a PDF/Office export becomes a consumer
  without re-solving headless Chromium.

## Consumers

| App | Status | Calls |
|---|---|---|
| Proposal Forge | Phase 1 (this change) | `http://gotenberg.document-render.svc.cluster.local:3000` |
| Ecosystem Control | Consumer (added 2026-06-09) | same |
| Project Tracker | Phase 2 (local-dev first; add netpol + authz principal on cluster deploy) | same |

When a new consumer comes online you must, in this namespace:
1. add its namespace to `allow-ingress-from-consumers` (05-network-policies.yaml), and
2. add its SPIFFE principal to `allow-consumers-to-gotenberg` (06-authorization-policy.yaml),
and in the consumer's namespace add an `allow-egress-to-document-render` NetworkPolicy.

## The cage (why an HTML→PDF service is safe here)

An HTML→PDF renderer is an SSRF risk: Chromium could be coaxed into fetching
in-cluster URLs (OpenBao, Keycloak, kube-apiserver, metadata). Contained in
four independent layers — any one failing is still contained:

1. **NetworkPolicy (primary):** default-deny egress, **DNS only**. No
   kube-apiserver, no in-cluster services, no internet. Chromium has nowhere to
   go. (`05-network-policies.yaml`)
2. **Gotenberg in-app guards:** `CHROMIUM_DENY_PRIVATE_IPS`,
   `CHROMIUM_DENY_PUBLIC_IPS`, `WEBHOOK_DISABLE`, plus the default `file:`
   deny-list (only the request's own `/tmp` uploads are readable).
   (`09-deployment.yaml`)
3. **Request shape:** consumers send HTML **and assets as multipart files**,
   never URLs — there is nothing for Chromium to fetch.
4. **Mesh identity:** ambient mTLS + an ALLOW `AuthorizationPolicy` restricts
   callers to specific SPIFFE principals. (`06-authorization-policy.yaml`)

## Known deviation: `readOnlyRootFilesystem: false`

This is the platform's one read-only-root exception. Chromium and LibreOffice
write to temp/home/caches and the upstream image is not built for a read-only
root (the upstream docs themselves ship `readOnlyRootFilesystem: false`). It is
still PSS-restricted (non-root UID 1001, drop ALL caps, seccomp RuntimeDefault,
no privilege escalation) and there is no Kyverno Enforce for read-only-root, so
it is policy-compliant. Writes are bounded to sized `emptyDir` volumes at `/tmp`
(HOME+TMPDIR) and `/dev/shm`. Flipping to `true` is a tracked hardening
follow-up — validate it against the LibreOffice Office→PDF path before changing.

## Image

`ghcr.io/jaupole/gotenberg:<ver>-secforge` is a **thin signed build** over the
public `docker.io/gotenberg/gotenberg` — same Gotenberg, with the Debian base +
Chromium/LibreOffice deps `apt-get upgrade`d to current security patches at
build time (a pure mirror can't be patched; upstream ships an older Chromium
than Debian already fixes). Produced by `.github/workflows/gotenberg-image-build.yml`
from `image/Dockerfile` (build → Trivy gate → cosign keyless sign). The GHCR
package is **public**, so no imagePullSecret is needed. Pin `09-deployment.yaml`
to the signed digest the workflow prints.

## Apply order

```
kubectl apply -f 01-namespace.yaml
kubectl apply -f 03-serviceaccount.yaml
kubectl apply -f 05-network-policies.yaml
kubectl apply -f 06-authorization-policy.yaml
kubectl apply -f 09-deployment.yaml   # after the image digest is filled in
kubectl apply -f 10-services.yaml
```
