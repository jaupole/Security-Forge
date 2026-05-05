# Operator Backlog

> Canonical index of post-phase follow-up items the operator must (or may) clear. Phase prompts open these; this file is the place to find them after that phase has closed.
>
> When you open a new backlog item, append a row here AND link the row from the closing phase block in PLAN.md. When you close one, mark it ✅ here AND remove the open reference from PLAN.md prose.
>
> Last updated: 2026-05-05 (post-Phase-9 audit cleanup Part 1 — opened #20 for Wazuh-apid auto-recovery)

## Legend

- ⬜ Open — not started
- 🟨 In progress
- ✅ Closed
- ⏸️ Blocked — note the blocker
- 👁️ Watching brief — keep an eye on the trigger condition

## Index

| # | Opened | Phase | Topic | Effort | Status | Blocking? |
|---|--------|-------|-------|--------|--------|-----------|
| 4 | 2026-04-30 | 7d.3 | OpenBao Transit unseal token TTL strategy — switch to `-period=720h` periodic tokens | small | ✅ Closed 2026-05-02 | — |
| 12 | 2026-05-02 | 7b.2 | Promtail verify phase-2 — flip Loki `compactor.retention_enabled` and confirm dashboard panels populate | medium | ⬜ Open | No (panels stay empty until flipped; not blocking apps) |
| 13 | 2026-05-02 | 7b | Migrate `BFF_VALKEY_PASSWORD` from K8s Secret env var to OpenBao via `apps/lib/secrets/`. Currently rides on `secforge.local/legacy-secret-env: OPS-MIGRATE-VALKEY-PW` annotation, expires 2026-07-31 | medium | ✅ Closed 2026-05-05 | — |
| 14 | 2026-05-02 | 7b.5 | Live verification of OTel scrubber sink — blocked on Docker Desktop containerd image-load quirk (`docker save \| ctr import` reports `total: 0.0 B`) | small | ⬜ Open | No (code change compiles + tests pass; live verify deferred) |
| 15 | 2026-05-02 | 7c | Istio Ambient AuthZ-denial observability — original log-level finding closed; ztunnel emits per-policy + per-clause RBAC trace at `RUST_LOG=trace` | n/a | ✅ Closed 2026-05-03 | — |
| 17 | 2026-05-02 | 7d.5 | Wazuh agent `client.keys` doesn't persist across pod restarts (enrollment-loop quirk) | ~30–60 min | ✅ Closed 2026-05-05 | — |
| 18 | 2026-05-02 | 7d.6 | Wazuh manager-side custom decoders for OpenBao + Keycloak JSON formats not loaded | ~1 hr | ✅ Closed 2026-05-05 | — |
| 19 | 2026-05-04 | 10.1.1 | MCP server reachability after Project Tracker moves to cluster — PT's Week-5 MCP server runs over stdio for Jason's local Claude Code → PT data; cluster deployment breaks the stdio model. Decide between (a) keep a local-only MCP shim that proxies to the cluster API, or (b) expose a bounded set of MCP-over-HTTP endpoints. Surface a small ADR. | small (decision) + medium (impl) | ⬜ Open | Soft — only blocks Week-5 PT work, not the Phase-10 cutover |
| 20 | 2026-05-05 | 9 (retro) | Wazuh-apid daemon stops after `wazuh-manager` pod restart and is not auto-recovered; Wazuh dashboard's "wait for dependencies" init then blocks indefinitely. Manual fix today: `kubectl exec -n wazuh wazuh-manager-0 -- /var/ossec/bin/wazuh-control restart`. Durable fix likely a sidecar/liveness/probe pattern that watches `wazuh-apid` PID. See `docs/05-claude-code-prompts/phase-09-retrospective.md` § "Wazuh-apid recovery (operational gotcha)". | medium (~2-4 hr) | ⬜ Open | Soft — only matters when manager pod restarts; Phase 10 cutover should NOT depend on Wazuh real-time event flow until this + #17/#18 are all clear |

## Severity / blocker bar

A backlog item is **blocking Phase 10** if any of the following are true:
- An application integrating in Phase 10 will need the platform capability the item gates
- The item describes a recurring outage or wedged-state pattern that can hit running apps
- The item describes a security-bright-line-rule violation per CLAUDE.md

Items marked **Soft** above are operationally relevant but not gating — Phase 10 can proceed; the operator just shouldn't forget about them.

## What this file is *not*

- It's not the place for ephemeral TODOs in code (use `// TODO(operator):` inline)
- It's not a replacement for ADRs — decisions still get an ADR
- It's not a replacement for the Phase prompt's "deliverables" list — those define done; this tracks what slips past done

## Conventions

- Keep numbering monotonically increasing across phases. Don't reuse numbers when items close.
- When closing, update the Status column with a date. Don't delete the row — it's history.
- The `Blocking?` column answers "should this be cleared before the next phase starts?" — be honest; default to "No" unless the case is clear.
- Cross-link from PLAN.md as `operator-backlog #N`; never duplicate the description.
