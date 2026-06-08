# ADR-0037: Dedicated document-rendering service (Gotenberg)

**Status**: Accepted
**Date**: 2026-06-08
**Decision-makers**: operator

## Context

Multiple ecosystem apps generate documents, and two of them ship **headless
Chromium** in their own image to do HTML→PDF:

- **Proposal Forge** — Puppeteer/Chromium for proposal PDFs (`server/services/export/pdf-export.service.ts`), plus a separate `docx` builder.
- **Project Tracker** — Puppeteer/Chromium for report/digest PDFs, plus `docxtemplater`.
- (Member Hub uses `pdfkit` — pure JS, no Chromium — and is out of scope.)

Carrying Chromium in an app image is expensive: it forces a fat (non-distroless)
base, drags a large CVE closure that makes Trivy scans slow/fragile (PF's image
is the one hitting scan timeouts), inflates memory and rollout time, and must be
patched **per app**. Each app also runs a parallel renderer per format, which can
visually drift.

## Decision

Stand up a single, shared, stateless **Gotenberg** service in a new
`document-render` namespace, exposing a REST API for HTML→PDF (Chromium),
Office→PDF (LibreOffice), and PDF merge. Ecosystem apps call it instead of
embedding Chromium. The app builds its document as HTML (or Office) once and
converts it via the service.

Consumers, by priority:
1. **Proposal Forge** — swap the Puppeteer path for the service behind a
   `PDF_RENDERER` flag; once parity is confirmed, remove Puppeteer/Chromium and
   rebase PF to a lean/distroless image.
2. **Project Tracker** — adopt the service *before* it is containerized, so it
   never ships Chromium.
3. Future apps reuse it.

The image is a **thin SecForge build** over the public
`docker.io/gotenberg/gotenberg` (same Gotenberg; the Debian base +
Chromium/LibreOffice deps are `apt-get upgrade`d to current security patches at
build time, then re-scanned + cosign-keyless-signed →
`ghcr.io/jaupole/gotenberg:<ver>-secforge`,
`.github/workflows/gotenberg-image-build.yml`). A pure mirror was the first
design but **cannot be CVE-patched** (it is upstream's exact bytes, and upstream
ships an older Chromium than Debian already fixes) — so the build, not a mirror,
is what actually delivers "one image to patch". This satisfies Kyverno
`restrict-image-registries` + `verify-image-signature-secforge` (Enforce)
without loosening either. The GHCR package is **public** (a thin layer over a
public image), so the namespace needs no pull secret and stays secret-free.

## Security posture

An HTML→PDF service is an SSRF risk. It is contained in four independent layers
(see `platform/manifests/document-render/README.md`):

1. **NetworkPolicy (primary):** default-deny egress, **DNS only** — no
   in-cluster services, no kube-apiserver, no internet.
2. **Gotenberg guards:** `CHROMIUM_DENY_PRIVATE_IPS`, `CHROMIUM_DENY_PUBLIC_IPS`,
   `WEBHOOK_DISABLE`, default `file:` deny-list.
3. **Request shape:** consumers send HTML + assets as files, never URLs.
4. **Mesh identity:** ambient mTLS + an ALLOW `AuthorizationPolicy` restricting
   callers to specific SPIFFE principals.

Pod is PSS-restricted (non-root UID 1001, drop ALL caps, seccomp RuntimeDefault,
no privilege escalation). The one deviation is `readOnlyRootFilesystem: false`
(Chromium/LibreOffice need writable temp/home; bounded to sized emptyDir
`/tmp` + `/dev/shm`) — policy-compliant, tracked as a hardening follow-up.

## Alternatives considered and rejected

- **Status quo (Chromium per app).** Rejected — the problem: fat images, N-way
  CVE patching, slow Trivy scans, renderer drift.
- **WeasyPrint / Prince (HTML→PDF without Chromium).** Lighter, smaller CVE
  surface, but lower CSS fidelity than Chromium (proposals are authored in a
  Chromium-based TipTap editor — WYSIWYG parity matters) and no Office→PDF or
  merge. Rejected on fidelity + scope.
- **browserless.** Chromium-only — no LibreOffice, no merge. Half of Gotenberg.
- **Roll our own Puppeteer+LibreOffice service.** That is Gotenberg; no reason to
  rebuild and maintain it.
- **Add `docker.io/gotenberg/*` to the registry allowlist + Audit signatures.**
  Cheaper, but loosens the allowlist and drops the renderer below the Enforce
  signature bar. Rejected in favor of build+sign into `ghcr.io/jaupole/*` (we own
  one image to patch anyway — that was the point).
- **Pure mirror (crane copy of upstream).** First design; rejected once Trivy
  showed upstream carries ~88 fixable Chromium CRITICALs (it ships Chromium 147;
  Debian already packages the fixed 149). A mirror is upstream's exact bytes and
  cannot be patched — so it could never pass the hard CVE gate. The thin
  `apt-get upgrade` build does.
- **Browserless engines (WeasyPrint / Browsershot / GoPdfSuit).** Evaluated
  2026-06-08. WeasyPrint (pure Python, no Chromium) is genuinely the smallest
  attack surface for HTML→PDF, but does **no** Office→PDF (kills the Word/Excel
  ambition), executes no JS, has lower CSS fidelity than the Chromium-based
  TipTap editor, and ships no maintained REST service (we'd own a wrapper).
  Browsershot is Puppeteer/headless-Chrome (same Chromium surface) + a PHP
  runtime. GoPdfSuit's native path is JSON-template (a full rewrite) and its
  HTML path is headless Chrome again; single-maintainer, young. Rejected: only
  Gotenberg also covers Office→PDF, and the Chromium CVE risk is a *maintained*
  one (patched build) rather than a reason to abandon Chromium. Revisit
  WeasyPrint if in-house Office→PDF is dropped and attack-surface reduction
  outranks fidelity.

## Consequences

- New namespace `document-render` with manifests under
  `platform/manifests/document-render/`. Apply via the standard kubectl flow;
  not auto-synced.
- A new GH Actions workflow builds+signs the image; version bumps / CVE
  refreshes are a `workflow_dispatch` (or a push to the image dir; Renovate can
  drive it later). A small Dockerfile is now maintained at
  `platform/manifests/document-render/image/`.
- PF and PT gain a runtime dependency on the service for PDF export. It is
  stateless and restarts fast; consumers degrade gracefully (export errors, app
  stays up) and PF keeps a feature-flag fallback during transition. PF's
  provider-doc path (Word/Docs) is an independent fallback for high-stakes
  proposals.
- Single-node memory: Chromium is memory-hungry; the pod is capped and runs one
  replica. Still net-better than PF *and* PT each pooling their own browser.

## Re-evaluation criteria

Revisit if: render throughput outgrows a single replica (add HPA / a second
replica + concurrency limits); a consumer needs JavaScript-heavy rendering that
warrants per-call Gotenberg flags; or the availability coupling proves too tight
(consider an in-app fallback renderer for the most critical path).

## References

- `platform/manifests/document-render/` — the manifests + README + image/Dockerfile
- `docs/03-runbooks/gotenberg-build-and-deploy.md` — operational procedure
- `.github/workflows/gotenberg-image-build.yml` — build + sign + scan
- [ADR-0032 — Istio gateway replaces ingress-nginx](./0032-istio-gateway-replaces-ingress-nginx.md) (mesh context)
