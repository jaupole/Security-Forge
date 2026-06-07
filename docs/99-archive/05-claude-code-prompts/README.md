> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Claude Code Prompts — Phase by Phase (Local Edition)

This directory contains the prompts you'll copy and paste into Claude Code, one phase at a time. Read [first-claude-code-session.md](../00-getting-started/05-first-claude-code-session.md) before starting if you haven't.

> **Source of truth:** [PLAN.md](../../PLAN.md) is the canonical execution-order + status table. The phase doc lists below mirror PLAN.md; if they diverge, **PLAN.md wins**. Phase doc headers carry that same notice.

## How to use these

Each phase document has:
1. **Navigation header** — prev/next phase, depends-on/blocks, status (mirrors PLAN.md)
2. **Prerequisites** — what must be true before starting
3. **Goal** — one sentence
4. **What you (the human) need to do first** — manual steps
5. **Prompt for Claude Code** — the block you copy-paste
6. **Success criteria** — verify before moving on
7. **Troubleshooting** — common issues
8. **What's next** — pointer to the next phase

## ⚠️ Filename order ≠ execution order

The filenames in this directory **do not sort lexically into execution order**. Specifically:

- `phase-06.10b-...` sorts before `phase-06b-0-...` lexically (`.` < `b`), but in execution order 06.10b runs **first** (it absorbs into the Phase 6 flow), then 6b-0 (token-exchange spike), then 6b-api-pattern (6b-1).
- `phase-06b-2-outbound-secrets.md` sorts after `phase-06b-api-pattern.md` (which is **6b-1**) lexically, but the two are **independent and can run in parallel**.
- The `7b` / `7c` / `7d` phases all run **after** Phase 7 ✅ but are independent of each other.
- The Fix-after-07 remediation package runs **between** the 7-series and Phase 9, but lives at `Fix after 07/` (not in this directory).

**Always consult [PLAN.md § Dependency graph](../../PLAN.md#dependency-graph-corrected-execution-order) for the current execution order.** The phase index below uses execution-order rows, not filename-sort.

## The phases (execution order)

| # | Phase | File | Estimated time | Current status |
|---|---|---|---|---|
| 0 | Prerequisites verification | [phase-00-prerequisites.md](./phase-00-prerequisites.md) | 1 hour | ✅ 2026-04-28 |
| 1 | Foundation (cluster services) | [phase-01-foundation.md](./phase-01-foundation.md) | 2–3 days | ✅ 2026-04-28 |
| 2 | Workload Identity (SPIRE) | [phase-02-spire.md](./phase-02-spire.md) | 1–2 days | ✅ 2026-04-29 |
| 3 | Identity Provider (Keycloak) | [phase-03-keycloak.md](./phase-03-keycloak.md) | 3–5 days | ✅ 2026-04-29 |
| 3-fu | Phase 3 follow-up — kcadm-admin service-account pattern (ADR-first) | (see PLAN.md § Phase 3 follow-up) | 1 day | ⬜ MUST run before Phase 9 |
| 4 | Authorization (SpiceDB) | [phase-04-spicedb.md](./phase-04-spicedb.md) | 2 days | ✅ 2026-04-29 |
| 5 | Secrets (OpenBao) | [phase-05-openbao.md](./phase-05-openbao.md) | 2–3 days | ✅ 2026-04-30 |
| 6 | Service Mesh + BFF | [phase-06-istio-bff.md](./phase-06-istio-bff.md) | 4–5 days | ✅ 2026-04-30 |
| 6.10b | VSO + secret cleanup | [phase-06.10b-vso-and-secret-cleanup.md](./phase-06.10b-vso-and-secret-cleanup.md) | half day | ✅ 2026-04-30 |
| 6b-0 | Token-exchange spike | [phase-06b-0-token-exchange-spike.md](./phase-06b-0-token-exchange-spike.md) | 2 hr | ✅ 2026-04-30 — **NO-GO** ([ADR-0012](../02-decisions/0012-token-exchange-feasibility.md)) |
| 6b-1 | API Auth Pattern (audience-at-login) | [phase-06b-api-pattern.md](./phase-06b-api-pattern.md) | 2 days | ⬜ Ready — design resolved 2026-05-01 |
| 6b-2 | Outbound Secrets + Guardrails | [phase-06b-2-outbound-secrets.md](./phase-06b-2-outbound-secrets.md) | 2 days | ⬜ independent of 6b-1 |
| 7 | Observability | [phase-07-observability.md](./phase-07-observability.md) | 4 days | ✅ 2026-04-29 → 2026-05-01 |
| ☆ | Fix-after-07 remediation package | [Fix after 07/](../../Fix%20after%2007/) | 1–2 days | 🟨 in progress — Sessions 1–4 across §A/B/C/D/E/F |
| 7b | Post-6b-2 Monitoring Wire-up | [phase-07b-post-6b2-monitoring.md](./phase-07b-post-6b2-monitoring.md) | 1–2 days | ⬜ HOLD until 6b-2 ✅ |
| 7c | Istio SPIRE-as-CA + PeerAuth STRICT | [phase-07c-istio-spire-ca-and-strict.md](./phase-07c-istio-spire-ca-and-strict.md) | 1–2 days | ⬜ |
| 7d | Rotation + housekeeping batch | [phase-07d-rotation-housekeeping.md](./phase-07d-rotation-housekeeping.md) | 1 day | ⬜ |
| 8 | Privileged Access (Teleport, **optional**) | [phase-08-teleport.md](./phase-08-teleport.md) | 2 days | ⬜ optional |
| 9 | Hello World end-to-end demo | [phase-09-hello-world.md](./phase-09-hello-world.md) | 2–3 days | ⬜ blocked on 6b-1, 3-fu, Fix-after-07 |
| 10 | Integrate Proposal Forge + Project Tracker | [phase-10-integrate-proposal-forge-project-tracker.md](./phase-10-integrate-proposal-forge-project-tracker.md) | 3–5 weeks | ⬜ |
| 11 | Develop additional apps | [phase-11-develop-apps.md](./phase-11-develop-apps.md) | open-ended | ⬜ |

Total to operational platform with Hello World: ~3-5 weeks part-time. Faster than the cloud edition because no cloud account work, no multi-environment setup, faster rebuild cycles.

## Skip-able phases

For local-only development, you can defer:
- **Phase 8 (Teleport)** — direct kubectl from Docker Desktop works fine; Teleport's value is in cert-based access for production-realistic admin workflows. Skip and document the gap if you don't care.
- **Parts of Phase 7 (Wazuh specifically)** — Loki + Prometheus + Grafana might be enough for local. You can add Wazuh later when you go to staging/prod.

If you skip something, write an ADR documenting it. Future-you needs to know.

## Don't skip the others

Each phase depends on the previous (see [PLAN.md § Dependency graph](../../PLAN.md#dependency-graph-corrected-execution-order) for the full picture). SpiceDB before SPIRE means you have to retrofit SPIFFE-based identity into your already-deployed SpiceDB. Keycloak before its database is set up means you misconfigure connections. Just follow the execution-order table above.

## A note on the cloud edition

If you find yourself ready to migrate to AWS or another cloud, the AWS-Edition phase prompts (saved separately in your `docs/06-reference/` if you kept them) become applicable. Most of the work is replacing local primitives with cloud equivalents:
- Postgres pods → RDS
- MinIO → S3
- File-based KMS → AWS KMS
- mkcert → Let's Encrypt
- hosts file → Route 53

Your application code, Helm charts, BFF, SpiceDB schema, OpenBao policies, Wazuh rules — all unchanged.

## Ready?

Start with [phase-00-prerequisites.md](./phase-00-prerequisites.md).
