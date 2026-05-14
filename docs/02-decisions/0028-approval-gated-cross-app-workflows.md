# ADR-0028: Approval-Gated Cross-App Workflows

**Status**: In progress (stub — slot reserved)
**Date**: 2026-05-08 (slot claim); content TBD when implemented
**Decision-makers**: Project owner

## One-line description

Cross-app promotions (e.g., `managerapp` pursuit → `proposalapp` proposal; `proposalapp` proposal → `managerapp` project) are first-class workflow records with explicit approval gates. A user with the relevant `workflow_*` permission initiates; one or more users with `approve_workflow` (and role-specific permissions like `view_finance` for proposal→project) approve; only on full approval does the destination resource get created.

## Context to be filled in

This stub reserves the slot per CLAUDE.md ADR conventions. Full content lands when workflow approvals are implemented in Phase 7 of the ecosystem identity plan.

See:
- Plan file: `C:\Users\jaupo\.claude\plans\alright-need-you-to-crispy-sunset.md` §2.5 for the schema and flow.
- [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md) for the `approve_workflow` permission and SpiceDB workflow definitions.
