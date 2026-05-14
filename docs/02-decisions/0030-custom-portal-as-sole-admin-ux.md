# ADR-0030: Custom Portal as Sole Admin UX; Keycloak Default UI Never Shown to End Users

**Status**: In progress (stub — slot reserved)
**Date**: 2026-05-08 (slot claim); content TBD when implemented
**Decision-makers**: Project owner

## One-line description

The ecosystem ships a custom Vite/React portal that owns 100% of the end-user identity, organization, role, app-admin, and workflow-approval UX. All operations call the Keycloak Admin API and the control-plane API on the user's behalf — Keycloak's own UI is never displayed to end users. Keycloak's admin console remains accessible to the platform operator on a separate hostname (per the existing CLAUDE.md bright-line rule), gated to operator IPs.

## Context to be filled in

This stub reserves the slot per CLAUDE.md ADR conventions. Full content lands when the portal is shipped (Phase 2–4 of the ecosystem identity plan).

See:
- Plan file: `C:\Users\jaupo\.claude\plans\alright-need-you-to-crispy-sunset.md` §1.4 and §4 for the portal scope and screens.
- CLAUDE.md "Things that should NEVER happen" rule about Keycloak admin console hostname isolation — this ADR is consistent with that rule.
- [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md) for the role-management UX the portal exposes.
