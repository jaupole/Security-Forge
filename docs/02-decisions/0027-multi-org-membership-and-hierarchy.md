# ADR-0027: Multi-Organization Membership and No-Cascade Hierarchy

**Status**: Accepted
**Date**: 2026-05-08 (slot claim) · 2026-07-06 (promoted from stub; dead plan-file reference removed)
**Decision-makers**: Project owner
**Relates**: [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md) (the role model this hierarchy interacts with); the membership implementation lives in Ecosystem Control (`organization_memberships`, org hierarchy).

## One-line description

Users can belong to multiple organizations simultaneously; organizations can have a
parent/child hierarchy; **roles do NOT cascade** from parent to sub-org (sub-orgs are
independent for member/role purposes); hierarchy is used only for navigation, billing
rollup, and the `create_sub_org` permission.

## Decision

- **Multi-org membership.** A user (Keycloak `sub`) can be a member of many organizations.
  Membership + role assignment is per-(org, user) — there is no global user role. Control's
  `organization_memberships` is the system of record; the active org is resolved at sign-in
  from Control's `GET /api/v1/me` and held server-side (not a client-trusted claim).
- **Parent/child hierarchy, NO role cascade.** An org may have a parent. Hierarchy is used
  ONLY for: navigation grouping, billing rollup, and gating the `create_sub_org` permission.
  A role granted in a parent org confers **nothing** in a sub-org — sub-orgs are independent
  tenants for member and role purposes.

## Rationale

Cascading roles down a hierarchy is the usual source of accidental cross-tenant privilege
(a parent-org admin silently gaining write on every sub-org). Keeping membership and roles
strictly per-org makes tenant isolation the default and hierarchy a purely organizational
convenience. It also keeps RLS simple: every tenant table scopes on a single `org_id`, never
a "this org or any ancestor" predicate.

## Consequences

- Per-org membership rows and role grants; no global roles. Fine-grained authz is enforced
  in SpiceDB per resource; hierarchy relations there are navigation/billing only, not
  permission inheritance.
- Billing rollup and navigation must walk the hierarchy explicitly (it is not implied by
  access).
- **Note**: this ADR predates the DB-unification canonical spine
  ([ADR-0029](./0029-per-app-database-strategy.md) / [ADR-0041](./0041-canonical-core-data-spine.md)).
  Memberships remain Control-owned; the canonical `people` directory (ADR-0041, P1) links to
  membership by `kc_sub` but does not change this membership/hierarchy model.
