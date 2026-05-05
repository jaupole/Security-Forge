# Operator Backlog

> Canonical index of post-phase follow-up items the operator must (or may) clear. Phase prompts open these; this file is the place to find them after that phase has closed.
>
> When you open a new backlog item, append a row here AND link the row from the closing phase block in PLAN.md. When you close one, mark it ✅ here AND remove the open reference from PLAN.md prose.
>
> Last updated: 2026-05-05 (Phase-10-readiness audit — opened #22 (CNPG Ready=False NetworkPolicy gap, surfaced during 7c-1) + #23 (Wazuh filebeat → indexer x509 + missing ssl/password config; root cause for empty `wazuh-alerts-*` indices))

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
| 21 | 2026-05-05 | 7c-2 | Phase 7c-2 — SPIRE-as-CA cutover + multi-ns STRICT expansion + trust-domain unification cluster.local → secforge.local. Pre-req: validate the helm-values diff in `infrastructure/istio/authzpol-strict-7c2-draft/helm-values-spire-ca.draft.diff` against the upstream Istio + SPIRE compatibility matrix at https://istio.io/latest/docs/ops/integrations/spire/. Existing 7c-2 prep (AuthorizationPolicy templates, baseline capture, draft diff) parked at `infrastructure/istio/authzpol-strict-7c2-draft/`. Scope: (a) flip Istio to use SPIRE as external CA (disable Citadel), (b) ambient-enroll keycloak / spicedb / openbao / observability / teleport namespaces, (c) rewrite `app`-ns AuthorizationPolicy principals from `cluster.local/...` to `secforge.local/...`, (d) flip mesh-wide PeerAuthentication PERMISSIVE → STRICT staged ns-by-ns, (e) **removes the CNPG-PERMISSIVE workload-scoped override (`infrastructure/istio/05-peer-auth-app-cnpg-permissive.yaml`) introduced in 7c-1** once openbao + postgres-operator + observability are mesh-enrolled, (f) close the ADR-0010 deferral. ADR-0024 / operator-backlog cross-reference: removal of override is the 7c-2 closeout signal. | 1-2 day operator window | ⬜ Open | Soft for Phase 10 — apps go into STRICT in app ns on day one under cluster.local (already in force from 7c-1); trust-domain unification is a separate concern and does not gate Phase 10 |
| 22 | 2026-05-05 | 7c-1 | CNPG cluster `secforge-app-db` Ready=False since 2026-04-29 (lastTransitionTime: 2026-04-29T22:03:54Z) — `postgres-operator` ns → CNPG pods on `:8000` (status-extraction endpoint) blocked by NetworkPolicy `allow-openbao-to-secforge-app-db` which only permits `openbao→5432`. Data plane is unaffected (Phase 9 E2E passed under this condition; openbao→CNPG dynamic-cred mint works through 7c-1's PERMISSIVE override). What's broken: postgres-operator's status reporting feeds CNPG `Cluster.status.phase=Healthy`, so backups / version-upgrade signal / failover hooks operate blind. Fix: add a NetworkPolicy ALLOW for `postgres-operator → app/secforge-app-db:8000` (mirror the existing pattern but with the postgres-operator ns selector + port 8000). Surfaced during Phase 7c-1 cutover (commit `c409913`); confirmed pre-existing by toggling STRICT off mid-cutover and observing the same i/o timeout. | small (~15 min) | ⬜ Open | Soft — data plane works, Phase 10 apps query the database directly without depending on `Cluster.status`; risk is that real CNPG faults could hide behind the persistent Ready=False until the gap closes |
| 23 | 2026-05-05 | 9 (retro) | Wazuh manager-side filebeat → indexer pipeline broken at TLS + auth. Real OpenBao + Keycloak events flow correctly to the manager (alerts.log shows ~30s-cadence rule matches against `/host/var/log/pods/openbao_*` and Keycloak audit lines), but `wazuh-alerts-*` indices don't exist on the indexer at all — only `wazuh-monitoring-*` (agent-keepalive). Root cause confirmed via `filebeat test output`: handshake fails with `x509: certificate signed by unknown authority`. Inspection of `/etc/filebeat/filebeat.yml` on `wazuh-manager-0` shows the `output.elasticsearch:` block has no `ssl.certificate_authorities`, no `ssl.certificate`, no `ssl.key` (all four ssl directives are commented out), and `password:` is empty. The `wazuh-filebeat-certs` Secret has the right material (`filebeat.pem`, `filebeat-key.pem`, `root-ca.pem` matching the indexer root by SHA-256 fingerprint), but filebeat isn't told to use any of it. Existing runbook troubleshooting recipe at `docs/03-runbooks/wazuh-operations.md § "Filebeat in manager pod logs x509: certificate signed by unknown authority"` assumes a CA-mismatch — both CAs match here, so that recipe doesn't apply. Likely fix: investigate whether the chart's `inject-filebeat-config` initContainer was supposed to populate the ssl block + admin password but failed silently (Phase 7.2 vendor chart at `infrastructure/wazuh/vendor/wazuh/`); add the four ssl directives + admin password to the rendered config. Until closed, Wazuh shows nothing in Discover and downstream PT/PF audit-event verification (Phase 10.{N}.7) cannot rely on Wazuh as a sink. | medium (~2-4 hr; chart investigation + config patch + cert-bundle plumbing) | ⬜ Open | Soft for Phase 10 — Loki / Tempo cover the audit-evidence path today; Wazuh sink is still a coverage gap. Should close before Phase 10 apps land if SIEM coverage is in scope for the cutover. |

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
