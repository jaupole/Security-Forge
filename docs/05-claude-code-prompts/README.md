# Claude Code Prompts — Phase by Phase (Local Edition)

This directory contains the prompts you'll copy and paste into Claude Code, one phase at a time. Read [first-claude-code-session.md](../00-getting-started/05-first-claude-code-session.md) before starting if you haven't.

## How to use these

Each phase document has:
1. **Status checklist** — track your progress
2. **Prerequisites** — what must be true before starting
3. **Goal** — one sentence
4. **What you (the human) need to do first** — manual steps
5. **Prompt for Claude Code** — the block you copy-paste
6. **Success criteria** — verify before moving on
7. **Troubleshooting** — common issues
8. **What's next** — pointer to the next phase

## The phases

| # | Phase | Estimated time | Status |
|---|---|---|---|
| 0 | [Prerequisites verification](./phase-00-prerequisites.md) | 1 hour | ⬜ |
| 1 | [Foundation (cluster services)](./phase-01-foundation.md) | 2-3 days | ⬜ |
| 2 | [Workload Identity (SPIRE)](./phase-02-spire.md) | 1-2 days | ⬜ |
| 3 | [Identity Provider (Keycloak)](./phase-03-keycloak.md) | 3-5 days | ⬜ |
| 4 | [Authorization (SpiceDB)](./phase-04-spicedb.md) | 2 days | ⬜ |
| 5 | [Secrets (OpenBao)](./phase-05-openbao.md) | 2-3 days | ⬜ |
| 6 | [Service Mesh + BFF](./phase-06-istio-bff.md) | 4-5 days | ⬜ |
| 7 | [Observability](./phase-07-observability.md) | 2-3 days | ⬜ |
| 8 | [Privileged Access (Teleport, optional)](./phase-08-teleport.md) | 2 days | ⬜ |
| 9 | [Hello World end-to-end demo](./phase-09-hello-world.md) | 2-3 days | ⬜ |
| 10 | [Develop your three apps](./phase-10-develop-apps.md) | open-ended | ⬜ |

Total to operational platform with Hello World: ~3-5 weeks part-time. Faster than the cloud edition because no cloud account work, no multi-environment setup, faster rebuild cycles.

## Skip-able phases

For local-only development, you can defer:
- **Phase 8 (Teleport)** — direct kubectl from Docker Desktop works fine; Teleport's value is in cert-based access for production-realistic admin workflows. Skip and document the gap if you don't care.
- **Parts of Phase 7 (Wazuh specifically)** — Loki + Prometheus + Grafana might be enough for local. You can add Wazuh later when you go to staging/prod.

If you skip something, write an ADR documenting it. Future-you needs to know.

## Don't skip the others

Each phase depends on the previous. SpiceDB before SPIRE means you have to retrofit SPIFFE-based identity into your already-deployed SpiceDB. Keycloak before its database is set up means you misconfigure connections. Just do them in order.

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
