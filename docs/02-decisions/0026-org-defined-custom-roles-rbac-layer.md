# ADR-0026: Org-Defined Custom Roles as an RBAC Layer on SpiceDB ReBAC

**Status**: Accepted
**Date**: 2026-05-08
**Decision-makers**: Project owner
**Supersedes / amends**: extends [ADR-0008](./0008-authz-schema.md) (does not invalidate it)

## Context

ADR-0008 established a three-tier ReBAC schema (`tenant` → `app` → resource) with a small fixed set of relations: `tenant#admin`/`member`, `app#admin`/`user`, `document#owner`/`editor`/`viewer`. That model is correct for the platform but exposes a UX problem when the customer is a **B2B organization with its own internal hierarchy and naming conventions**.

Concretely, the ecosystem the platform serves (`proposalapp` = Proposal Forge, `managerapp` = Project Tracker, plus a roadmap of `invoiceapp`/`contactsapp`/`pmapp`) needs:

1. **Customer-defined role names**. A consulting firm calls one role "Senior Estimator." A construction firm calls the equivalent role "Pricing Lead." The platform vendor cannot enumerate every customer's titles.
2. **Customer-defined permission compositions**. Some firms separate "approve" from "edit"; others combine them. The atomic permissions (view, edit, comment, approve) are universal; how they bundle into named roles is per-customer.
3. **Position independence**. The same model must serve a 2-person consulting shop and a 200-person engineering firm. Pre-baked role hierarchies (Junior < Senior < Manager < Director) are wrong for both extremes.
4. **Granularity beyond what SpiceDB models cleanly**. Per-row-type permission flags like "can see cost rates," "can export," "can initiate cross-app workflow promotion," "can approve invitations" are real customer requirements that don't fit into a clean owner/editor/viewer trio.

ADR-0008's schema can be extended (it explicitly anticipates per-app resource definitions), but extending it once per customer-defined role would mean editing the SpiceDB schema for every new tenant — a non-starter operationally.

## Decision

**Adopt a layered authorization model with three concerns, each owned by a different actor:**

| Layer | Owned by | Mechanism | Stored in |
|---|---|---|---|
| 1. Atomic permission catalog | Platform (us) | SpiceDB schema relations and permissions | `infrastructure/spicedb/schema.zed` |
| 2. Org-defined named role bundles | Org Admin (customer) | Postgres rows that compose atomic permissions into named roles | `ecosystem_control` Postgres DB |
| 3. App-admin per-role page/section visibility config | App Admin (customer) | Postgres rows mapping (role × app × surface) to visibility | `ecosystem_control` Postgres DB |

**The user-facing model is RBAC** (named roles with composed permissions, assigned to users). **The enforcement engine is SpiceDB ReBAC** (relationships between users and resources). Role assignments expand into SpiceDB relationship writes; revocations expand into deletes. The Postgres bundle table is the source of truth; SpiceDB is the rebuildable index.

### Atomic permission catalog (Layer 1)

Extends ADR-0008's schema. The expanded `app` definition adds these atomic permissions (full schema in the plan file referenced below):

- `view` (existing)
- `edit` (existing)
- `administer` (existing)
- `create` — author new top-level resources
- `comment` — leave comments without `edit`
- `approve` — approve workflow transitions; implies `comment`
- `view_finance` — see cost rates / margins / financial data
- `export` — bulk export to file
- `invite` — initiate invitation (still subject to approval queue)
- `approve_invite` — decide on a pending invitation
- `approve_workflow` — decide on a cross-app promotion request
- `create_sub_org` — create child organizations under this org
- `time_submit`, `time_approve`, `time_view_all` — for the future PM app
- `workflow_pursuit_to_proposal`, `workflow_proposal_to_project` — cross-app initiation

The catalog grows as new apps land. Adding a permission is a SpiceDB schema PR + a validator-test PR; existing roles and assignments are untouched.

### Org-defined named role bundles (Layer 2)

In Postgres `ecosystem_control` DB, tables `org_roles` and `org_role_permissions` hold per-org named roles and their permission composition. An org admin uses the portal to create a role like "Senior Manager" by ticking permission checkboxes. The system writes:

- One row in `org_roles` for the named role.
- One row per ticked (permission × app) cell in `org_role_permissions`.

When the role is assigned to a user (`org_user_roles` table), a worker expands the bundle into SpiceDB relationship writes:

```
app:proposalapp@<orgid>#editor@user:<uid>
app:proposalapp@<orgid>#commenter@user:<uid>
app:proposalapp@<orgid>#approver@user:<uid>
...
```

Plus `organization:<orgid>#member@user:<uid>` (the structural membership for ADR-0008's tenant tier).

Revocation deletes the same set in one transaction.

**Built-in role templates** are seeded per org on creation: `Org Administrator`, `Application Administrator (per app)`, `Manager`, `Senior Manager`, `Editor`, `Viewer`, `Commenter`, `Approver`, `Finance`. Org admins can edit, delete, or extend any of them.

### App-admin per-role surface visibility (Layer 3)

Each app declares a manifest of "feature surfaces" — pages and sections (field-level deferred per the plan file). App admins use the portal's app-admin UI to set each surface to `visible | hidden | readonly` for each org role.

Stored in `app_feature_surfaces` (the manifest, declared at app deploy time) and `org_role_app_config` (the per-role overrides). The BFF reads this config when serving routes; the frontend reads the same config when rendering UI.

Layers 2 and 3 reinforce each other at the BFF: if a role lacks the underlying atomic permission (Layer 1/2), the request is blocked regardless of surface config; surface config is the "even if you have the permission, don't show this UI" layer.

### Object ID convention (extends ADR-0008)

App instances are now scoped to their org: `app:proposalapp@<orgid>` instead of just `app:proposalapp`. This is necessary because the same app code serves many tenants and each tenant's role assignments live on their own app instance. Resources continue to use the org-prefixed form from ADR-0008 (`document:tenant_<id>/<resource_id>`), where `tenant_<id>` and `<orgid>` are the same UUID.

## Rationale

### Why RBAC on top of ReBAC, not pure ReBAC

Pure ReBAC requires customers to think in relationships ("Alice is the editor of document 4471"). Real B2B customers think in roles ("Alice is a Senior Manager"). The Layer 2 bundles let the customer's mental model stay RBAC while the engine stays ReBAC. We get ReBAC's revocation latency and per-resource granularity for free; we add RBAC's familiarity at the edge.

Inverting this — pure RBAC at the engine level — would either explode the role table (one role per resource × user combination) or require denormalized ACL tables that ADR-0008 explicitly rejected.

### Why bundles in Postgres, not in SpiceDB Caveats

SpiceDB Caveats compose permissions at evaluation time using request-context predicates. That's powerful for time-of-day or step-up-auth gating but wrong for "Alice's Senior Manager role grants 7 atomic permissions on this app." Caveats would mean every CheckPermission call carries the full role definition, blowing past the request-size limits. Postgres-stored bundles let us keep CheckPermission requests small and the role definition stays editable without schema migrations.

### Why expand bundles into SpiceDB writes, not query-time joins

Every app's BFF calls SpiceDB's `CheckPermission` on the hot path. Joining bundles at query time (compose role at evaluation) would add a Postgres roundtrip and bundle-evaluation logic to every check. Expanding once on assignment (write-side) keeps the read path identical to pure ReBAC, and SpiceDB's dispatch cache continues to work.

The trade-off: bundle edits require fan-out writes to all assigned users. With SpiceDB's WriteRelationships supporting batches, this is manageable; for a 50-user org changing one role, that's 50 × N permissions written in one batch. Acceptable.

### Why "organization" instead of "tenant"

ADR-0008 used "tenant" — a vendor-side term. Customers don't think of themselves as a "tenant"; they think "my organization." The Layer 1 schema renames the SpiceDB definition `tenant` → `organization` for user-facing alignment. Object IDs and code references update with it. ADR-0008's substance is unchanged; this is a vocabulary cleanup.

(For platform internals that still use "tenant" — RLS column names like `tenant_id`, ADR-0018's "tenant isolation" — both terms refer to the same UUID and the rename is cosmetic.)

### Why Layer 3 (per-app surface config) instead of more atomic permissions

You could model "hide the pricing page from Editor role" as a SpiceDB permission `view_pricing_page`. Doing this for every page × section in every app would explode the atomic catalog into hundreds of permissions, and adding a new page would require platform-side schema changes. Layer 3 puts page/section visibility under app-admin control without touching the SpiceDB schema. Atomic permissions stay coarse and ecosystem-wide; Layer 3 stays fine-grained and app-local.

### Why field-level visibility is deferred

Field-level redaction (e.g., hiding the `cost_rate` column while showing the rest of the pricing page) is the natural extension of Layer 3. It's deferred because (a) every app would need its data layer to participate, and (b) the obvious cases are covered by `view_finance` at Layer 1. Revisit when concrete use cases beyond financial data emerge.

## Alternatives considered and rejected

### A. Per-tenant SpiceDB schema customization

**Pros**: every tenant gets exactly the schema they want.
**Cons**: SpiceDB has one schema per cluster. Per-tenant schemas mean per-tenant clusters, blowing up operations by orders of magnitude. Rejected.

### B. Pure RBAC with role-per-resource entries

**Pros**: simpler conceptual model.
**Cons**: explodes the role table at scale (every "Alice can edit document N" is a row); revocation requires fan-out across the resource set; inheritance rules become application-side logic. Rejected — this is the failure mode ADR-0008 already documented.

### C. Bundles evaluated at query time (no fan-out write)

**Pros**: bundle edits take effect instantly with no writes.
**Cons**: every CheckPermission becomes a Postgres bundle lookup + N SpiceDB checks instead of one. Read path is the hot path; we optimize for it. Rejected.

### D. Vendor-defined roles only (no customer customization)

**Pros**: simpler product, fewer support questions.
**Cons**: every B2B SaaS that's tried this has eventually shipped role customization. The vendor's vocabulary never matches the customer's. Rejected as a known anti-pattern.

### E. App-admin field config in each app's own DB

**Pros**: per-app autonomy.
**Cons**: org-wide reporting (e.g., "show me all roles that have access to financial fields anywhere") requires querying every app's DB. Centralizing in the control plane keeps audit and reporting tractable. Rejected.

## Consequences

### What this commits us to

- The control plane DB (`ecosystem_control`) becomes a critical-path service: every role assignment and every BFF authorization decision touches it. It needs the same uptime/backup posture as Keycloak and SpiceDB.
- The portal app becomes the primary admin UX for the entire ecosystem (org admin + app admin + workflow approvals). End users never see Keycloak's UI — its admin console is operator-only on a separate hostname per the existing CLAUDE.md bright-line rule.
- Apps must declare their feature-surface manifest at deploy. Adding a page without declaring the surface means it's silently visible to every role; CI should validate that every routed page has a surface entry (deferred to per-app migration).
- The role-assignment worker that expands bundles to SpiceDB relationships is a new platform service. It needs idempotency, retry, and a reconciliation mode (rebuild SpiceDB state from the Postgres bundles).
- The SpiceDB schema is now substantially larger than ADR-0008. Validator tests (`infrastructure/spicedb/tests/`) must cover every new permission rule.

### What this preserves

- ADR-0008's three-tier model is unchanged in structure; we add new relations and rename `tenant` → `organization`.
- ADR-0018's RLS strategy is unchanged. The `tenant_id` (now `org_id`) UUID is still the source-of-truth column, sourced from the JWT, set per-transaction via `SET LOCAL`.
- ADR-0008's per-app extension pattern is unchanged. Apps still declare their resource definitions; this ADR adds a parallel mechanism for declaring atomic permissions and feature surfaces.
- Caveats path is unaffected — Layer 1 is still pure SpiceDB schema, so any future Caveats land cleanly.

### Known gaps

1. **Bundle migration on permission deprecation.** If we remove an atomic permission from the catalog (rare), every bundle referencing it needs to be updated. Plan: add migration tooling when first needed.
2. **Bundle assignment fan-out latency.** Assigning a role with 10 permissions to 1000 users writes 10,000 SpiceDB tuples. Should be <1s with batching but warrants load testing before any tenant scales beyond 1000 members.
3. **Role-edit reapplication.** Editing a bundle requires re-expanding for all current assignees. Implementation needs to handle this transactionally to avoid temporary permission gaps.
4. **No cross-org role templates.** Each org's bundles are private. A future "marketplace of role templates" (let one org publish a bundle that another can copy) is out of scope.

## Re-evaluation criteria

Re-open this ADR if:

1. The expansion-on-assignment write fan-out becomes a measured bottleneck (>1s for typical role assignments).
2. A genuine use case for cross-org role sharing emerges (likely indicates we should add a template/marketplace concept).
3. SpiceDB introduces native "named permission groups" or equivalent that would eliminate the Postgres bundle layer.
4. We need to support a customer with non-UUID identity for orgs/users (would change the SpiceDB ID format).

## References

- [ADR-0008](./0008-authz-schema.md) — the three-tier ReBAC schema this ADR extends.
- [ADR-0018](./0018-multi-tenancy-rls-strategy.md) — RLS defense in depth, unchanged by this ADR.
- Plan file: `C:\Users\jaupo\.claude\plans\alright-need-you-to-crispy-sunset.md` — the ecosystem identity, tenancy, and authorization plan that motivated this ADR. Contains the full SpiceDB schema, control-plane DB tables, portal UX, sequencing, and verification plan.
- Memory: `project_ecosystem_identity_plan.md` in user's auto-memory.
- Future ADRs (to be written when those decisions are implemented):
  - Multi-organization membership and no-cascade hierarchy
  - Approval-gated cross-app workflows (pursuit→proposal, proposal→project)
  - Per-app DB strategy and shared-UUID logical FKs
  - Custom portal as the sole admin UX (no Keycloak default UI for end users)
