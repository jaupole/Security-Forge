# ADR-0028: Approval-Gated Cross-App Workflows

**Status**: Accepted — engine live in Control; `proposal_to_project` lane (award handoff) specified here and built in phases. `pursuit_to_proposal` lane remains a reserved sibling.
**Date**: 2026-05-08 (slot claim) · 2026-06-15 (proposal→project contract specified)
**Decision-makers**: Project owner

## One-line description

Cross-app promotions (`managerapp` pursuit → `proposalapp` proposal; `proposalapp` proposal → `project_manager` project) are first-class **workflow records owned by Ecosystem Control**. A user in the source app with the relevant `workflow_*` permission **initiates** the promotion, attaching a typed **source snapshot** (the proposed destination data). Approvers with `approve_workflow` (plus role-specific permissions like `view_finance` for proposal→project) **decide**; only on full approval does the **destination app execute** the promotion, creating the destination resource and writing its id back to the workflow. This ADR specifies the `proposal_to_project` lane — the **award handoff** from Proposal Forge to Project Manager.

## Context

We are moving the ecosystem from "apps that share auth + org context" to "one cohesive system where work flows between apps." The first real inter-app **data** flow (beyond identity/org-context and the read-only PM→BM feed) is: a Proposal Forge proposal is **awarded**, and it is time to start the project in Project Manager — carrying the pricing/estimate (labor hours, rates, the Direct Labor Multiplier), the deliverables, travel, and subcontractors, assigned to a named PM with the right access, with as much detail as possible for the PM to succeed.

The plumbing already exists in **Control** (`src/api/routes/workflows.ts`, migration `006_workflows.sql`):

- `pending_workflows`: `workflow_type` (`pursuit_to_proposal` | `proposal_to_project`), `source_app_id`, `source_resource_id`, `destination_app_id`, `initiator_user_id`, `org_id`, **`payload` JSONB** (the proposed destination data + `sourceSnapshot`), `status` (`pending_approval` → `approved` → `executed` | `failed`, or `rejected`), **`completed_resource_id`** (the created destination resource).
- `workflow_approvals`: per-role decisions (`manager`, `finance`, …) — see [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md).
- Notifications: `createNotification` already fires `workflow.approval_needed` / `workflow.decided` to the bell (org-wide ecosystem notifications feed, live fleet-wide).

The engine "**stops at `approved`**" today (inline TODO): the **destination-app execution**, and the **typed snapshot contract** for `proposal_to_project`, were never built. That gap is the work this ADR authorizes.

## Decision

Model the award handoff as the Control `proposal_to_project` workflow. Define the snapshot contract below; PF initiates, Control orchestrates (approval gate deferred — see Phasing), PM executes. Everything PM receives is **fully editable** — the negotiated award routinely differs from the bid.

### The `proposal_to_project` snapshot contract (`payload.sourceSnapshot`)

```jsonc
{
  "proposalName": "string",          // subject label (Control reads this)
  "clientName": "string",
  "rfpNumber": "string|null",
  "contractType": "TIME_AND_MATERIALS | FIRM_FIXED_PRICE | COST_PLUS",
  "periodOfPerformance": "string|null",
  "awardAmount": "decimal",          // the negotiated award (PM reconciles to this)
  "bidAmount": "decimal",            // proposed total, for proposed-vs-awarded
  "directLaborMultiplier": "decimal",// PROPOSAL-level (see PF change below) → PM project DLM
  "assignedPmUserId": "kc-sub",      // the PM (Keycloak subject)
  "assignedPmName": "string",
  "grantPmAccess": true,             // PF author's security selection, DEFAULT ON

  "deliverables": [                  // ExtractedTask/CLIN → PM WBS deliverable
    { "ref": "3.1.1", "name": "string", "description": "string", "sortOrder": 0 }
  ],

  "laborByGroup": [                  // PRIMARY labor unit = discipline-group totals
    {
      "group": "Cybersecurity Engineering",
      "deliverableRef": "3.1.1|null",
      "totalHours": "decimal",
      "blendedLoadedRate": "decimal",
      "personnel": [                 // backing detail — PM may drill in + adjust
        { "laborCategory": "Sr Cyber Eng", "person": "string|null",
          "hours": "decimal", "baseRate": "decimal", "loadedRate": "decimal" }
      ]
    }
  ],

  "trips": [ /* full Trip detail — kept editable; proposed != accepted */ ],
  "subcontractors": [ { "name": "string", "scope": "string", "amount": "decimal" } ],
  "additionalCosts": [ { "category": "string", "description": "string", "amount": "decimal" } ]
}
```

### Flow

1. **PF initiates** (source app, `workflow_initiate`): builds the snapshot from the proposal's pricing summary, the operator picks the **PM** and confirms the **award amount** and the **grant-PM-access** toggle (default on), → `POST` Control `/workflows` with `workflow_type: proposal_to_project`, `destination_app_id: project_manager`.
2. **Control** stores the `pending_workflows` row, resolves approvers, and (when the gate is enabled) notifies `workflow.approval_needed`. **MVP: the gate is auto-satisfied** (initiator with `workflow_initiate`) — the formal multi-role approval is a later phase.
3. **PM executes** (destination app, on `approved`): consumes the snapshot → creates the project, sets `managerUserId` = assignedPm, seeds **WBS** from deliverables, seeds **labor estimates by group** (totals + personnel backing) and **fixed estimates** for travel/subs/additional, sets the **project DLM**. Writes the new project id to `completed_resource_id`; Control marks `executed` and fires `workflow.decided`.
4. **PM is alerted** via the bell and opens the project to **validate, assess personnel, build the plan, and reconcile to the actual award + negotiated terms** (all editable). Resource approval is a later workflow.

### Locked design decisions

- **DLM is per proposal, not per position.** PF moves `directLaborMultiplier` off `RateCard` to the proposal, mapping 1:1 to PM's existing project-wide DLM. (This supersedes the earlier "per-line multiplier in PM" idea — no longer needed.)
- **Labor granularity = group totals**, with the personnel bid + rate cards carried as adjustable backing detail. The PM cares about totals per discipline group, with the option to drill in.
- **Subcontractors** are tracked in PM's **Procurement** module (vendors/agreements), with the dollar rolled into the budget. (Revisit if a lighter cost-line is preferred.)
- **Access**: `grantPmAccess` (default on) → PM writes a SpiceDB `project#manager@user:<pm>` grant on execution. **Supervisors** (org admins / `manage_members`) can reassign the PM; reassignment rewrites the grant. Aligns with [ADR-0008](./0008-authz-schema.md) three-tier ReBAC and [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md).

## App-side changes

| App | Change |
|---|---|
| **Proposal Forge** | Proposal-level DLM (schema + rate math); an `AWARDED`-style state + "Send to Project Manager" action (pick PM, confirm award $, access toggle); build the snapshot from the pricing summary; `workflow_initiate` → Control. |
| **Control** | No schema change — engine exists. Wire the destination-execution callback / status transition past `approved`; expose the snapshot to the destination app; keep notifications. |
| **Project Manager** | Authenticated execution endpoint that consumes the snapshot → create project + WBS + estimates (group labor + fixed) + DLM + manager; SpiceDB grant; bell alert; everything editable; proposed-vs-awarded reconciliation view (later). |
| **Security Forge** | PF→Control and Control→PM (or PM→Control pull) egress allowlist entries; audience so the destination call authorizes; no new platform components. |

## Consequences

- **Cohesion**: Control becomes the single orchestration + approval + notification hub for inter-app promotions; apps stay decoupled behind the typed snapshot. The same engine already serves `pursuit_to_proposal`.
- **Editability is a hard requirement** — the snapshot seeds, it does not lock. The award amount drives reconciliation, not the bid.
- **Deferred**: the formal multi-role approval gate (manager + finance) ships after the data path works; PF "push on award" can later replace operator-initiated send; the `pursuit_to_proposal` lane is unaffected.
- **Open items**: KC-subject → app-user resolution on both ends; whether PM **pulls** the snapshot from Control or Control **pushes** to PM's BFF (lean: PM pulls on execute, keeping mapping logic in PM); egress + audience wiring.

## Phasing

0. **This ADR** (contract) — done.
1. **PF**: proposal-level DLM + "Send to Project Manager" (assign PM, award $, access) → initiate Control workflow with the snapshot.
2. **PM**: execution endpoint → create project from snapshot (WBS + group-labor + fixed estimates + DLM + manager), all editable; write back `completed_resource_id`.
3. **Glue**: bell alert to the PM + SpiceDB access grant + supervisor reassign; egress/audience.
4. **Polish**: proposed-vs-awarded reconciliation; subcontractor/Procurement mapping.
5. **Later**: multi-role approval gate (manager + finance); PF auto-push on award status.

## References

- Control engine: `Ecosystem Control/src/api/routes/workflows.ts`, migration `006_workflows.sql`.
- [ADR-0008](./0008-authz-schema.md) three-tier ReBAC · [ADR-0012](./0012-token-exchange-feasibility.md) token-exchange NO-GO (audience-at-login) · [ADR-0026](./0026-org-defined-custom-roles-rbac-layer.md) `approve_workflow` + custom roles · [ADR-0029](./0029-per-app-database-strategy.md) per-app DBs with shared Control UUIDs.
- Ecosystem notifications feed (the bell): org-wide, system publish endpoint; live fleet-wide.
