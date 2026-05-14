# ADR-0027: Multi-Organization Membership and No-Cascade Hierarchy

**Status**: In progress (stub — slot reserved)
**Date**: 2026-05-08 (slot claim); content TBD when implemented
**Decision-makers**: Project owner

## One-line description

Users can belong to multiple organizations simultaneously; organizations can have a parent/child hierarchy; **roles do NOT cascade** from parent to sub-org (sub-orgs are independent for member/role purposes); hierarchy is used only for navigation, billing rollup, and the `create_sub_org` permission.

## Context to be filled in

This stub reserves the slot per CLAUDE.md ADR conventions. Full content lands when the multi-org membership model is implemented in Phase 2 of the ecosystem identity plan.

See:
- Plan file: `C:\Users\jaupo\.claude\plans\alright-need-you-to-crispy-sunset.md` §1.1 for the decided design.
- [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md) for the role model this hierarchy interacts with.
