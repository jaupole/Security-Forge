# ADR-0038: Ecosystem block-document framework (web · email · PDF · dashboards)

**Status**: Accepted
**Date**: 2026-06-09
**Decision-makers**: operator

## Context

Member Hub already ships a security-hardened **block document** system for each
org's public website (Member Hub ADR-0003: the Website Designer / Puck editor →
`site_pages.page_kind='blocks'` → in-origin `BlockRenderer`). Its defining
property is that **operator input becomes typed, schema-validated props, never
markup** — which is what lets it render as first-party React in the app origin
instead of a sandboxed iframe. The older raw-HTML tier (`page_kind='html'`)
still exists as a sandboxed escape hatch.

We want to (a) widen the catalog of blocks ("widgets" — tables, buttons,
contact forms that send email from the browser without `mailto:`, donations),
and (b) reuse the same authoring model on **other surfaces**: transactional /
campaign **email**, **PDF documents** (starting with invoices), and **editable
dashboards** in Portal and Member Hub. Today the block model is web-only,
lives entirely inside Member Hub, and has no server-side renderer (blocks only
render client-side via Puck component functions).

## Decision

Adopt a single **block-document framework** with **per-surface catalogs** and a
**render-target seam**, extracted into a shared package so every app
(Portal, Member Hub, Proposal Forge, Project Tracker) can author and render
blocks. **It is a shared library, not a new backend service.**

### Framework + catalogs (not one giant union)

- **Shared core** (the framework): the document envelope, the `validateDocument`
  hardening harness (`.strict()`, tree-wide id/depth/byte caps), the security
  field rules (`graphicId` UUID media references, the `href` scheme allowlist,
  closed-enum design-token styles), and a **render-target abstraction**.
- **Shared presentational blocks** reused across surfaces: hero, richText,
  image, columns, **table**, **button**, spacer, factsCard.
- **Per-surface catalogs** extend the core with surface-specific blocks:
  - *website*: interactive forms (rsvp, enrollment, **contactForm**),
    **donation**, and the sandboxed `customHtml` escape hatch.
  - *email*: preheader + per-recipient `{{variable}}` blocks; **no** customHtml
    (no sandbox off-web), **no** interactive blocks.
  - *pdf/invoice*: line-items / totals / page-rule blocks.
  - *dashboard*: data-bound widgets (KPI, sparkline, donut, funnel, feed, table)
    built on the existing `@jaupole/ecosystem-ui` dashboard primitives.
- Each block **declares which targets it supports** and how it renders per
  target. A block meaningless on a target simply isn't in that catalog.

### Render targets

| Target | Renderer | Trust |
|---|---|---|
| Web | first-party React (Puck `<Render>` / `BlockRenderer`) | typed props ⇒ safe in-origin |
| Dashboard | first-party React + live data | typed props; data fetched under RLS/SpiceDB, never embedded in the doc |
| Email | **server** → inlined-table HTML (Node, no React) | static, no JS at all |
| PDF/Invoice | **server** → print HTML → `document-render` (Gotenberg, ADR-0037) | static, sandboxed render service |

The one genuinely new piece of infrastructure is the **server-side renderer**
(`renderBlocksToHtml(doc, { target })`) that email and PDF need; web/dashboard
keep rendering client-side. PDF reuses the existing Gotenberg service — no new
service is introduced.

### Library, not a service — and why

| Concern | Home | Why |
|---|---|---|
| contract + `validateDocument` | shared library (isomorphic) | pure stateless code; a service would add a hop to validate JSON for no benefit |
| editor (Puck config) + web render components | shared library (React) | browser code |
| server render → HTML (email/PDF) | shared library (Node fn) | emits a string; callable in-process |
| render → PDF **bytes** | existing `document-render` service | already built (ADR-0037) |
| storage, interactive intake, data-binding | **per-app** | needs each app's RLS, SpiceDB, org context, Postmark/Stripe config — centralizing recreates every app's data layer and breaks the bounded-context rule (Control owns org/member; apps never JOIN across) |

A central "block service" would have to reach into every app's data to render
data-bound widgets and run intake — fighting the whole architecture. The only
concern that benefits from being a service (PDF) already is one.

### Package shape (multi-entry, so backends never import React)

Extend `@jaupole/ecosystem-ui` (or a sibling package) with subpath exports:

- `…/blocks/schema` — Zod contract + `validateDocument` (isomorphic)
- `…/blocks/render-html` — server renderer (Node, no React)
- `…/blocks/editor` + `…/blocks/react` — Puck config + web render components (browser)

Each app imports the framework, registers its own surface catalog, and supplies
its own storage / intake / data-binding.

## Security

The invariant is unchanged and carries to every target: **typed props, never
markup.** Off-web targets are *stricter* — email/PDF render to static HTML with
no JS and accept only the safe typed subset (no `customHtml`, no interactive
blocks). The new risk surface is the interactive website blocks (contact,
donation) — anonymous side effects (send email / take money) — which extend the
existing intake pattern (honeypot + `withTxNoOrg`/`SYSTEM_USER_UUID` +
surface master-switch + audit `emit()`) with **Cloudflare Turnstile +
per-IP/per-org rate-limit + an explicit per-org enable toggle**. Dashboard
widgets store *query intent*, never data; the server resolves it under RLS +
SpiceDB (generalizing today's `eventGrid`/`sponsorWall` data-bound blocks).

## Consequences

- Member Hub's existing block system is the reference implementation; the
  extraction (Phase 2) is a refactor, not a rewrite.
- New blocks are added in one place and become available to every app.
- A web/server render-parity discipline is required (the editor canvas, the web
  `BlockRenderer`, and the server `renderBlocksToHtml` must agree). Long-term
  this argues for a single set of render functions shared by all three.

## Phasing

1. **Widen the website catalog** *(in Member Hub, now)* — `table`, `button`,
   `contactForm` (intake + Postmark + Turnstile), `donation` (Checkout).
2. **Extract shared core + server renderer** — move the framework to the shared
   package; build `renderBlocksToHtml` (web parity first).
3. **Email-from-blocks** — compose campaign + transactional templates with the
   block editor → server-rendered inlined email HTML.
4. **PDF/invoices-from-blocks** — branded document templates → Gotenberg.
5. **Dashboard editing** — authenticated data-bound widget catalog with
   per-user/org saved layouts.

Phase 1 lands inside Member Hub's existing module so it ships value immediately;
its blocks are written cleanly so Phase 2 lifts them with minimal change.

## Open questions (resolve before Phase 2)

- Final package boundary (extend `ecosystem-ui` vs a new `@jaupole/blocks`).
- Email render approach (hand-rolled inliner vs MJML vs react-email).
- The dashboard data-binding contract (how a widget declares a data source the
  server can satisfy safely under RLS/SpiceDB).

## Prior art / references

- Member Hub **ADR-0003** — the original block-document contract (D1–D4).
- **ADR-0037** — the shared `document-render` (Gotenberg) service.
- `Member Hub/src/modules/site-pages/blocks.ts` — the contract + `validateDocument`.
- `Member Hub/client/src/components/public/BlockRenderer.tsx` — the in-origin renderer.
