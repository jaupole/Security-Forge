# SecForge Platform — Local Edition Build Plan

This is the canonical plan for standing up the IAM platform on your local Docker Desktop Kubernetes. Each phase has a corresponding Claude Code prompt document in [docs/05-claude-code-prompts/](./docs/05-claude-code-prompts/).

**Print this page and check off as you go.**

---

## Phase status legend

- ⬜ Not started
- 🟨 In progress
- ✅ Complete and verified
- ⏸️ Blocked (note why)
- 👁️ Watching brief — not a phase to execute; a condition to monitor (lives in the Watching briefs section, not the main phase table)

---

## Phase order — quick reference (execution order)

> **MANDATORY:** when a phase status changes, update BOTH the detail block below AND this quick-reference row in the same edit. PLAN.md authoritativeness depends on this table staying current. Bump the "Last updated" date on every edit.
> Last updated: 2026-05-05 (audit cleanup — operator-backlog #22 closed: `allow-postgres-operator-to-secforge-app-db` NetworkPolicy added at `infrastructure/cloudnativepg/clusters/app-db-netpol-operator-status.yaml`, CNPG `secforge-app-db` Ready=True at 2026-05-05T20:08:11Z. 7c-1 prose under "Phase 7c-1" amended to point at #22 closure instead of "tracked separately". Quick-ref table unchanged — no phase-status delta.) Previous: 2026-05-05 (Phase 10.1.2 — SpiceDB schema additions for Project Tracker landed: `definition organization` + five `project_tracker/*` definitions appended to `infrastructure/spicedb/schema.zed` matching the audit doc verbatim; five new validator tests under `infrastructure/spicedb/tests/project-tracker/` cover owner-can-edit, member-can-view, non-member-denied, org-admin-cascades, task-inherits-from-parent-project; all 9 platform+PT tests green via `bash infrastructure/spicedb/tests/run.sh`; schema applied to live SpiceDB; round-trip read matches semantically. `tests/run.sh` updated to recurse one level so per-app subdirs are picked up. Side fixes during apply: stale `spicedb-config` Secret reference in 4 operational scripts (`apply-schema.sh`, `zed.sh`, `check-permissions.sh`, `seed-test-data.sh`) repointed to VSO-rendered `spicedb-config-vso` per ADR-0023 — closes the second issue from Phase 9 SpiceDB followups memory.) Previous: 2026-05-05 (post-Phase-9 audit cleanup Part 1 + Part 2 — Part 1 landed three small bookkeeping items: opened operator-backlog #20 for Wazuh-apid auto-recovery, wrote ADR-0025 codifying the JWT auth role token_ttl > credential default_ttl rule, amended Phase 10 prompt with the three BFF correctness checks (oidc-sub-mapper, direct audience-mapper, htu canonicalization). Part 2 landed Phase 7c-1: namespace-scoped STRICT PeerAuthentication in `app` ns under the existing `cluster.local` trust domain, with a workload-scoped PERMISSIVE override on the CNPG cluster (`cnpg.io/cluster=secforge-app-db`) for non-mesh callers from openbao / postgres-operator / observability. test-page Phase-1 demo torn down as separate atomic commit (the only ingress-nginx → app/non-CNPG path under STRICT). 7c split into 7c-1 ✅ (today) and 7c-2 ⬜ (operator-backlog #21 — SPIRE-as-CA + multi-ns expansion + trust-domain unification cluster.local → secforge.local; removes the CNPG PERMISSIVE override at closeout). Verified green: authzen-facade Ready under STRICT, openbao→app/secforge-app-db:5432 TCP-connectable through the override, openbao→spicedb dynamic-cred mint passes, zero ztunnel deny-policy events for 5 min. Pre-existing: CNPG cluster Ready=False since 2026-04-29 (postgres-operator → :8000 status-extraction blocked by a NetworkPolicy gap that pre-dates 7c-1; not caused by STRICT, observable both with and without the new resource). ADR-0010 amended to record the 7c-1 partial cutover; status stays "Accepted with deferral" until 7c-2 closes the trust-domain flip.) Previous: 2026-05-05 (S3 + S4 audit cleanup — Wazuh #17 + #18 + Valkey-pw #13 all closed: agent `client.keys` persistence verified across pod restart; manager-side `local_decoder.xml` + `secforge_local_rules.xml` mounted, 8473 rules enabled, OpenBao + Keycloak shapes confirmed via `wazuh-logtest`; helloworld-bff template migrated to fetch Valkey password via `apps/lib/secrets/` with refresh-on-AUTH-failure mirroring `helloworld-backend/db.go`'s 28P01 path, deployment manifest cleaned, Kyverno admits dry-run, Phase 10 BFF clones inherit the correct pattern). Previous: 2026-05-04 (Session 7 — **Phase 9 🟨 In progress; checkpoint 9.10.5 PASSED; teardown next.** Happy path verified end-to-end as jason (OIDC+TOTP login → BFF session → DPoP-bound JWT → backend → SpiceDB CheckPermission → dynamic Postgres creds via OpenBao → document fetch from `helloworld.documents`). Alice's view-only and bob's no-access flows match the design's access matrix. 5/6 negative tests pass with runtime evidence; one (#5 expired-JWT auto-refresh) marked partial pending a 5-min wait. **Several library + config bugs surfaced and fixed during 9.8 debugging:** (1) `apps/lib/api-auth/client.go` was minting client-assertion JWTs with RS256+no-kid; Keycloak `helloworld-bff` is configured `token.endpoint.auth.signing.alg=PS256` and the verifier indexes by Keycloak-shaped kid (DER-PKIX SHA-256 base64url). Library now signs PS256+kid. (2) Same library's `Middleware.ValidateInbound` accepted only `Authorization: Bearer` — RFC 9449 §7.1 requires `DPoP` for DPoP-bound tokens. Library now accepts both schemes. (3) BFF's `proxyToBackend` was minting DPoP `htu` from the upstream (in-cluster) URL while the backend's `canonicalHTU` reads X-Forwarded-* and reconstructs the public URL — causing every request to fail `htu_mismatch`. BFF now mints proof using `inboundHTU(r)` (the public URL the user requested). (4) BFF `sessionTTL` interpreted Keycloak's `refresh_expires_in: 0` (offline-token sentinel) as "already expired" → 1-second TTL. Now treats `RefreshExp == 0` as "no expiry from refresh token" and uses `idleTTL`. (5) Keycloak `helloworld-bff` client lacked an `oidc-sub-mapper` — access tokens had no `sub` claim, breaking SpiceDB's regex validation. Mapper added directly to client. (6) Keycloak `helloworld-api` audience mapped via per-client mapper (not via a missing client scope, since binding the scope to a private-key-jwt client failed silently in our setup). **SpiceDB orphan-lease bug also fixed at root:** JWT auth role token TTL bumped above credential default_ttl (`spicedb-datastore-refresher` 10m → 15h, `helloworld-backend` 10m → 90m) so OpenBao's parent-token expiry no longer revokes child credentials. **Side commits:** Tempo memory limit 1Gi → 2Gi (was OOM-killing under Grafana tag-load queries); app-ns CPU quota 2 → 4 cores; nginx `sub_filter` injects per-request CSP nonce into the static HTML (so the BFF's `strict-dynamic` CSP allows `<script src=/app.js>`); container build now `docker save | ctr import`s into Docker Desktop's containerd k8s.io namespace because the daemon image store is separate. **Wazuh observability gap acknowledged:** Keycloak audit forwarding to Wazuh is deferred per Phase 7d follow-ups — Phase 9.9 verified Loki / Tempo / Prometheus only, with the Wazuh row marked N/A pending the integration. **Wazuh-apid recovery memory recorded:** `wazuh-apid` daemon stops after manager pod restarts and is not auto-recovered, masking the dashboard's wait-for-dependencies init. Manual restart pattern documented in memory.)


| Phase | Notes |
|-------|-------|
| ✅ Prerequisites | 2026-04-28 |
| ✅ Foundation | 2026-04-28 |
| ✅ Workload Identity (SPIRE) | 2026-04-29 |
| ✅ Identity Provider (Keycloak) | 2026-04-29; manual TOTP enrollment done |
| ✅ Authorization Engine (SpiceDB) | 2026-04-29; AuthZEN façade live |
| ✅ Secrets Management (OpenBao) | 2026-04-30; OIDC admin login working |
| ✅ Service Mesh and BFF | Istio Ambient + helloworld-bff live |
| ✅ 6.10b — VSO + secret cleanup | folded into Phase 6 work |
| ✅ 6b-0 — Token-exchange spike (NO-GO) | see [ADR-0012](./docs/02-decisions/0012-token-exchange-feasibility.md) |
| ✅ Observability (Phase 7 mainline) | 7.0/7.1/7.3/7.4/7.5 (Sessions 1+2) + 7.6/7.7/7.8/7.9/7.10 (Session 3); 7-day SPIFFE-CSI soak in background |
| ✅ Phase 7.2 — Wazuh deployment | **Session 4 (2026-05-01)** complete: vendored `ileonelperea/wazuh-helm` 1.2.10 at `infrastructure/wazuh/vendor/`, indexer/manager/dashboard 1/1 Ready, indexer cluster green, dashboard live at https://wazuh.secforge.local/. Agent DaemonSet + OIDC federation + Keycloak/OpenBao log forwarding deferred to Phase 7d / follow-ups. See `### Path decision (2026-05-01)` and `docs/03-runbooks/wazuh-operations.md`. |
| ✅ 6b-1 — API Auth Pattern | **Complete 2026-05-01** — six signed commits (`d9996be` skeleton → `a6ce8d1` middleware → `07f86d9` client + Q3 verify → `06c87ef` audit → `db786fc` BFF wiring → commit-6 verification + docs + flip). `apps/lib/api-auth/` shipped (Middleware + Client + Audit per ADR-0014); `helloworld-bff` is the reference consumer. 84.2% line coverage, `-race -count=10` green. Q3 live curl deferred to operator (script at `infrastructure/lib/api-auth/verify-q3-refresh.sh`); library handles both Q3 outcomes. |
| ✅ 6b-2 — Outbound Secrets + Guardrails | **Complete 2026-05-02** — seven signed commits: `aa10402` ADR-0013 → `f82700a` `apps/lib/secrets/` outbound (88.7% cov) → `9803725` `apps/lib/errreport/` scrubber (89.7% cov) → `af152ea` `templates/app-repo/` + Trivy flip → `41e27d1` Kyverno (2 ClusterPolicies, 9/9 fixtures) + `apps/security-events-collector/` (67.3% cov) + CronJob → `f549775` BFF consumer wiring + AuthZEN ADR-0015 cross-ref → commit 7 closeout (8 verify scripts + run-all.sh + 6 runbooks + CLAUDE.md no-`.env` rule + Phase 10.{N}.5 update). Six guardrail layers operational; verify suite exercises every layer end-to-end. |
| ✅ 3 follow-up — kcadm-admin service-account pattern | **Complete 2026-05-01** — four signed commits (`824c3f0` ADR-0022 → `73f2d12` provisioning script → `225cd6e` four-script migration + `--otp` removal → commit-4 runbook + legacy-env purge + flip). Steady-state auth via `kcadm config credentials --client kcadm-admin --secret <fetched-from-OpenBao>`. Bootstrap is a one-time manual UI step per ADR-0022 § Bootstrap caveat. |
| ✅ 7b — Post-6b-2 Monitoring Wire-up | **Complete 2026-05-02** — Promtail + Loki + Grafana + PrometheusRule wired; weekly CronJobs scheduled; runbook updated; verify-08 phase-2 deferred to operator-backlog #12 |
| ✅ 7c-1 — STRICT in `app` ns under cluster.local | **Complete 2026-05-05** (option A — scope-limited cutover). Namespace-scoped STRICT PeerAuthentication on `app` ns; mesh-wide default stays PERMISSIVE; trust domain unchanged (still cluster.local). Workload-scoped PERMISSIVE override on `cnpg.io/cluster=secforge-app-db` keeps non-mesh callers (openbao + postgres-operator + observability) reachable. test-page Phase-1 fixture torn down as separate atomic commit. Verified: authzen-facade Ready, cross-boundary openbao → app/secforge-app-db:5432 connect succeeds, openbao → spicedb dynamic-cred mint passes, zero ztunnel deny-policy events on 5-min soak. ADR-0010 amended; deferral retained for 7c-2. |
| ⬜ 7c-2 — SPIRE-as-CA + multi-ns + trust-domain unification | tracked as operator-backlog #21. Pre-req: validate helm-values diff against upstream Istio + SPIRE docs. Drafts at `infrastructure/istio/authzpol-strict-7c2-draft/`. Removes the CNPG PERMISSIVE override at closeout. Soft for Phase 10. |
| ✅ 7d — Rotation + housekeeping batch | **Complete 2026-05-02** — 8 signed commits across 7d.1 + 7d.2 + Items 3, 4, 5, 6, 7. Both follow-ups closed 2026-05-05 in S3 audit cleanup: operator-backlog #17 (`client.keys` persistence — pre-registered key + K8s Secret + init-container injection; pod-restart preserves agent ID 010, manager logs zero re-enrollment) + #18 (manager-side decoders + rules — `local_decoder.xml` JSON_Decoder for kubelet pod-log lines + `secforge_local_rules.xml` rule range 100200-100299 for OpenBao + Keycloak shapes; 8473 rules total enabled; `wazuh-logtest` confirms actor/op/path populated). |
| ✅ ☆ Fix-after-07 remediation package | **Complete 2026-05-01.** See [Fix after 07/](./Fix%20after%2007/) and Phase 7 detail block; tagged `fix-after-07-complete`. |
| ✅ Privileged Access (Teleport — Phase 8) | **8a foundation ✅ 2026-05-02** + **8b prototype B ✅ 2026-05-03**. CE has no OIDC connector (Enterprise-only), so SSO uses GitHub OAuth (org `security-forge1`/team `platform-admins` → `admin`); Keycloak `teleport` client + `04-oidc-connector.yaml` preserved on disk for cloud-edition cutover. Browser + tsh CLI login + `kubectl exec` recording → MinIO all verified end-to-end. Helm values pin `proxy_listener_mode: multiplex` (default `separate` makes CLI dial 127.0.0.1:3023 which we don't forward). Known gaps: `admin` role still `system:masters` (scope-down at cloud cutover); no MinIO Object Lock on recordings; Wazuh forwarding of audit events deferred. See [ADR-0024 § Amendment 2026-05-03](./docs/02-decisions/0024-teleport-community-edition-local.md) + [docs/03-runbooks/teleport-operations.md](./docs/03-runbooks/teleport-operations.md). |
| ✅ Hello World End-to-End (Phase 9) | **Complete 2026-05-04** — 9.1–9.10.5 checkpoint passed (jason/alice/bob access matrix verified end-to-end; 5/6 negative tests with runtime evidence; #5 expired-JWT-auto-refresh marked partial). 9.12 teardown ran via `infrastructure/helloworld/teardown.sh`; 9.13 verified clean via `infrastructure/helloworld/verify-clean.sh` (all 8 residue checks pass; platform health intact). Library/config fixes shipped during the run: `apps/lib/api-auth` PS256+kid + `DPoP` scheme acceptance; BFF htu uses public URL via `inboundHTU(r)`; BFF `sessionTTL` handles `refresh_expires_in: 0` offline-token sentinel; Keycloak `helloworld-bff` got `sub` mapper + direct audience mapper for `helloworld-api`. SpiceDB orphan-lease bug fixed at root via JWT auth role token TTL bump (refresher 10m → 15h, helloworld-backend 10m → 90m). Side fixes: Tempo memory limit 1Gi → 2Gi (was OOM-killing under Grafana tag-load); app-ns CPU quota 2 → 4 cores; build.sh now `docker save | ctr import`s into Docker Desktop's containerd; nginx `sub_filter` injects per-request CSP nonce. **Wazuh row of 9.9** closed 2026-05-05 (operator-backlog #17 + #18; see Phase 7d row). **Screenshots skipped** by operator decision (durable artifacts are source code + ADR-0014/0015 + design doc). Reference source preserved at `apps/helloworld-{frontend,backend,bff}/`. |
| 🟨 Integrate Proposal Forge + Project Tracker (Phase 10) | **Started 2026-05-04**: 10.1.1 audit ✅, 10.1.2 SpiceDB schema additions ✅ (2026-05-05). 10.1.3+ pending. |
| ⬜ Develop Additional Apps (Phase 11) | open-ended; requires 10 ✅ |

### Dependency graph (corrected execution order)

```
Phase 0 (Prerequisites) ✅
  └─→ Phase 1 (Foundation) ✅
        └─→ Phase 2 (SPIRE) ✅
              └─→ Phase 3 (Keycloak) ✅
                    ├─→ Phase 3 follow-up (kcadm-admin) ✅ 2026-05-01 (four signed commits; ADR-0022 + kcadm-admin client + four migrated scripts + runbook)
                    └─→ Phase 4 (SpiceDB) ✅
                          └─→ Phase 5 (OpenBao) ✅
                                └─→ Phase 6 (Istio + BFF) ✅
                                      ├─→ Phase 6b-0 (Token-exchange spike) ✅ NO-GO → ADR-0012
                                      ├─→ Phase 6.10b (VSO + secret cutover) ✅
                                      ├─→ Phase 6b-1 (API Auth Library) ✅ 2026-05-01 (six signed commits; apps/lib/api-auth shipped)
                                      ├─→ Phase 6b-2 (Outbound Secrets + Guardrails) ✅ 2026-05-02 (seven signed commits; apps/lib/secrets/ extension + apps/lib/errreport/ + 5-layer guardrail stack + security-events-collector)
                                      └─→ Phase 7 (Observability) ✅
                                            ├─→ 7.0.a (SPIFFE-CSI startupProbe) ✅ (4 OpenBao pods; apps already self-heal — F-CLU-1)
                                            ├─→ 7.0.b (realm_access.roles debug) ✅ closed-with-evidence (defect is OpenBao 2.5.3 upstream)
                                            ├─→ 7.0.c (OIDC CLI redirect URI) ✅
                                            └─→ 7.1–7.10 (stack) ✅
                                                  ├─→ Phase 7b (Post-6b-2 monitoring) ✅ 2026-05-02 (Promtail+Loki+Grafana+PrometheusRule wired; weekly CronJobs scheduled; runbook updated; verify-08 phase-2 deferred to operator-backlog #12)
                                                  ├─→ Phase 7c (SPIRE-as-CA + STRICT) 🟨 UNBLOCKED 2026-05-03 — operator-backlog #15 closed (denial visibility achievable at ztunnel TRACE log level; original test was at wrong level); 1-2 day cutover window not yet allocated
                                                  └─→ Phase 7d (Rotation + housekeeping) ✅ 2026-05-02 (8 signed commits; 7d.1 + 7d.2 + Items 3+4+5+6+7; follow-ups #17 + #18 tracked separately, non-blocking)
                                                        ↓
                                                ☆ Fix-after-07 (this package) ✅ Complete 2026-05-01 (six signed commits; tagged `fix-after-07-complete`) ☆
                                                        ↓
                                                  ├─→ Phase 8 (Teleport) ✅ 8a ✅ 2026-05-02 + 8b prototype B ✅ 2026-05-03 (CE has no OIDC → pivoted to GitHub OAuth; e2e CLI + recording verified; ADR-0024 amended; runbook teleport-operations.md added)
                                                  └─→ Phase 9 (Hello World) ✅ 2026-05-04 (9.10.5 checkpoint + 9.12 teardown + 9.13 verify-clean all complete; reference source preserved at apps/helloworld-{frontend,backend,bff}/)
                                                          [needs: 1-7 ✅, 6b-1 ✅, 3 follow-up ✅, Fix-after-07 ✅, F-CLU-11 ✅ — all gates closed; Phase 8 is parallel/optional, not a blocker]
                                                        └─→ Phase 10 (Integrate apps) ⬜
                                                              [needs: 1-9 ✅, 6b-2 ✅]
                                                              └─→ Phase 11 (Develop apps) ⬜
```

> Source: [Fix after 07/00-audit-findings.md § Dependency graph](./Fix%20after%2007/00-audit-findings.md#dependency-graph-corrected-execution-order). Reproduced here so the canonical execution order lives at the top of PLAN.md, not buried in an audit document.

**Critical-path blockers for Phase 9:** Phase 7 ✅ → Phase 6b-1 ✅ → Phase 3 follow-up ✅ → Fix-after-07 ✅ → F-CLU-11 ✅. **All gates closed; Phase 9 operationally ready to start.**

### Watching briefs (not phases to execute)

These are conditions to monitor indefinitely. They don't move through ⬜ → 🟨 → ✅ like phases do. When a trigger fires, the brief converts into actual work (usually a re-spike, a re-evaluation, or a new ADR).

| Brief | Trigger(s) | Action when fired |
|-------|-----------|-------------------|
| 👁️ 6b-0 follow-up — Token-exchange re-evaluation | (a) Keycloak 26.4+ release with `token-exchange` / `admin-fine-grained-authz` stabilization in release notes; (b) cloud-edition Keycloak migration to a managed service that may have validated the path; (c) compliance-driven actor-chain audit requirement audience-at-login can't satisfy; (d) a downstream A→B→C call-chain where C must verify B's authority independently of A | Re-enable preview features in Keycloak CR, re-run Phase 6b-0 spike scripts (retained), append "Re-evaluation YYYY-MM-DD" section to [ADR-0012](./docs/02-decisions/0012-token-exchange-feasibility.md) |

---

## Phase 0 — Prerequisites *(half day)*
**Status: ✅ Complete (2026-04-28)**

Local toolchain installed and verified. Docker Desktop K8s enabled. Local DNS and TLS root CA set up.

**Deliverables:**
- WSL2 Ubuntu + tooling (kubectl, helm, k9s, mkcert, jq, yq, cosign, claude-code)
- Docker Desktop installed with Kubernetes enabled, 12+ GB RAM allocated
- mkcert local CA installed and trusted by your browser
- `*.secforge.local` resolves to 127.0.0.1
- Claude Code authenticated and working in this folder

**See:** [docs/05-claude-code-prompts/phase-00-prerequisites.md](./docs/05-claude-code-prompts/phase-00-prerequisites.md)

---

## Phase 1 — Foundation *(2-3 days)*
**Status: ✅ Complete (2026-04-28)**

Kubernetes platform services and the local equivalents of the cloud primitives.

**Deliverables:**
- Namespaces created with resource quotas
- cert-manager installed with mkcert as ClusterIssuer
- ingress-nginx installed
- Postgres operator with 5 databases (one per platform component)
- Valkey deployed
- MinIO deployed (S3-compatible object storage for audit logs and session recordings)
- Cosign + Kyverno admission controller (optional in dev mode but recommended)

**See:** [docs/05-claude-code-prompts/phase-01-foundation.md](./docs/05-claude-code-prompts/phase-01-foundation.md)

---

## Phase 2 — Workload Identity (SPIRE) *(1-2 days)*
**Status: ✅ Complete (2026-04-29)**

SPIRE provides cryptographic identity to every workload — same as the cloud edition, just without the cloud IAM federation.

**Deliverables (all verified):**
- SPIRE server (`spiffe/spire` Helm chart 0.28.4 / SPIRE 1.14.5), 1 replica StatefulSet, SQLite datastore on a 1Gi PVC
- Upstream CA: ECDSA P-256, self-signed, 10-year validity (Ed25519 unsupported by SPIRE's `disk` plugin)
- spire-agent DaemonSet, 1 pod (single-node cluster), k8s_psat + workload k8s/unix attestors
- spiffe-csi-driver DaemonSet exposing the Workload API socket to opted-in pods
- spire-controller-manager reconciling `ClusterSPIFFEID` CRDs
- Trust domain: `spiffe://secforge.local`
- 6 active `ClusterSPIFFEID` registrations: `default` (label-opt-in) + 5 namespace-scoped (`keycloak`, `spicedb`, `openbao`, `app`, `istio-system`)
- TTLs: 1h X.509 / 5m JWT / 24h CA
- Test workload (`infrastructure/spire/test-workload/`) successfully fetches X.509-SVID and JWT-SVID; chain verified against the upstream root

**Note:** No AWS IAM federation. Workloads use SPIFFE-ID-bound OpenBao roles for "I need credentials" scenarios — pattern documented in [docs/06-reference/spire-openbao-pattern.md](./docs/06-reference/spire-openbao-pattern.md), implementation deferred to Phase 5.

**See:** [docs/05-claude-code-prompts/phase-02-spire.md](./docs/05-claude-code-prompts/phase-02-spire.md)

---

## Phase 3 — Identity Provider (Keycloak) *(3-5 days)*
**Status: ✅ Complete (2026-04-29) — automated checks pass; manual TOTP enrollment done; bootstrap-admin path torn down.**

Keycloak deployed via the Operator. Two realms (platform, secforge-tenants) with TOTP-primary auth and recovery codes. Four BFF clients pre-registered with private_key_jwt + PAR + DPoP + PKCE. Admin console on isolated hostname with NetworkPolicy.

**Deliverables (all verified by `infrastructure/keycloak/verify.sh`):**
- Keycloak Operator 26.3.3 + Keycloak 26.3.3, 1 replica StatefulSet, Postgres backend
- Realm signing keys: RS256 (active) + PS256 advertised, RSA-OAEP enc, HS512 internal, AES — Keycloak default key provider (DB-backed); cloud KMS PKCS#11 deferred per [ADR-0006](./docs/02-decisions/0006-keycloak-keys-local.md)
- `platform` realm: TOTP-primary, recovery codes mandatory, idle 15 min / max 8h, remember-me 30d, no self-registration, no external IdP federation
- `secforge-tenants` realm: TOTP-primary, recovery codes mandatory, idle 30 min / max 12h, organizationsEnabled, registration disabled, email verification required
- Auth-factor model swapped from passkeys to TOTP+recovery-codes for the local-dev window per [ADR-0007](./docs/02-decisions/0007-totp-instead-of-passkeys-locally.md) — supersedes [ADR-0002](./docs/02-decisions/0002-local-passkey-via-windows-hello.md)
- 4 skeleton BFF clients in `secforge-tenants` (`helloworld-bff`, `proposal-forge-bff`, `project-tracker-bff`, `pm-bff`): client-jwt (private_key_jwt PS256), PAR + DPoP + PKCE-S256 required, implicit/ROPC/CIBA/device disabled, fullScopeAllowed=false, RFC 9068 typed access tokens, refresh-rotation with reuse detection
- Per-client RSA-2048 signing keys in `app/bff-jwt-*` Secrets (Phase 5 migrates to OpenBao)
- Two ingresses: `auth.secforge.local` (public OIDC) and `auth-admin.secforge.local` (admin console, source-IP allowlisted to docker0/loopback)
- Two-layer admin gating: Keycloak `hostname.admin` enforces application-side, ingress allowlist enforces network-side
- NetworkPolicies: default-deny ingress, allow ingress-nginx + operator + Phase 7 prometheus, egress to Postgres + DNS only
- SPIFFE-CSI volume mounted at `/spiffe-workload-api`; SVID `spiffe://secforge.local/ns/keycloak/sa/keycloak` issued by SPIRE
- Pod hardening: PSS=restricted enforced, drop ALL caps, no privesc, non-root UID 1000, seccomp RuntimeDefault, readOnlyRootFilesystem on operator (gap on keycloak container documented in iam-platform.md)
- `--features=recovery-codes,dpop` enabled (build-time augmentation; `startOptimized: false`)
- Event listener `jboss-logging` emits structured JSON to STDOUT for Phase 7 ingest
- Bootstrap admin (master realm) created by `apply.sh`, used once to seed the project owner's TOTP-enrolled `jaupole` (master) and `jason.upole` (platform) users, then **fully torn down**: `keycloak-bootstrap-admin` Secret deleted, master-realm `bootstrap-admin` user deleted, `bootstrapAdmin` block removed from the Keycloak CR. The operator's auto-managed `keycloak-initial-admin` Secret remains (functionally inert — Keycloak only consumes it if no admin user exists in master, which is not the case)

**Documentation:**
- Architecture: [docs/01-architecture/01-iam-platform.md](./docs/01-architecture/01-iam-platform.md)
- ADRs: [0006](./docs/02-decisions/0006-keycloak-keys-local.md), [0007](./docs/02-decisions/0007-totp-instead-of-passkeys-locally.md), [0002 (superseded)](./docs/02-decisions/0002-local-passkey-via-windows-hello.md)
- Runbooks: [keycloak-operations.md](./docs/03-runbooks/keycloak-operations.md), [realm-signing-key-rotation.md](./docs/03-runbooks/realm-signing-key-rotation.md)

**Deviations from original phase prompt** (all documented inline):
- TOTP+recovery-codes replaces passkeys for the local-dev window (user request — no hardware FIDO2 keys yet; ADR-0007)
- ADR file numbered 0006 not 0003 (0003 already used by cloudnativepg-vs-others)
- `keycloak` namespace ResourceQuota bumped from 2/3Gi to 4/8Gi to fit operator + Keycloak + concurrent realm-import jobs (jobs inherit Keycloak's 1700Mi memory request)
- `readOnlyRootFilesystem: false` on Keycloak container (Quarkus re-augmentation needs writable /opt/keycloak/lib/quarkus when `startOptimized: false`); long-term fix is custom image, deferred to production hardening
- Ingress `server-snippet` defense-in-depth dropped (disabled cluster-wide by ingress-nginx as a privesc vector); `hostname.admin` + dedicated admin Ingress + NetworkPolicy provide the equivalent split
- Postgres `sslmode=require` instead of `verify-full` — local edition gap; the CNPG-issued CA is already loaded in Keycloak's Java truststore, but tightening also requires JDBC `sslrootcert` path (deferred to production hardening)
- `allow-postgres-ingress` NetworkPolicy added (post-Phase-3.6 fix). Default-deny-ingress was correctly blocking ingress to the Postgres pod (same namespace), but Phase 3.6 didn't include an explicit Postgres ingress allow. Verified by Keycloak pod-restart on 2026-04-29 failing to obtain JDBC connection

**See:** [docs/05-claude-code-prompts/phase-03-keycloak.md](./docs/05-claude-code-prompts/phase-03-keycloak.md)

---

## Phase 3 follow-up — kcadm-admin service-account pattern *(1 day)*
**Status: ✅ Complete (2026-05-01)** — four signed commits (`824c3f0` ADR-0022 → `73f2d12` provisioning script → `225cd6e` four-script migration + `--otp` removal → commit-4 runbook + legacy-env purge + flip). [ADR-0022](./docs/02-decisions/0022-kcadm-admin-long-lived-credential.md) accepts the long-lived credential with 90-day rotation cadence (precedent: ADR-0006 realm signing keys), kubectl-exec OpenBao access path (option (b) — pattern consistency with existing OpenBao infrastructure scripts), and a documented union-of-roles grant table that's ADR-amended whenever a new kcadm script needs additional roles. Provisioning script `infrastructure/keycloak/clients/kcadm-admin.sh` is idempotent + supports `--rotate`. The four kcadm-using scripts (`verify.sh`, `clients/openbao.sh`, `realms/bootstrap-bff-clients.sh`, `realms/create-tenant-test-user.sh`) source `infrastructure/keycloak/_lib/kcadm-auth.sh` and authenticate via `kcadm_admin_auth`. The legacy `KCADM_USER`/`KCADM_PASSWORD`/`KCADM_TOTP` env-var pattern is purged across the repo. Bootstrap is a one-time manual UI step (chicken-and-egg) documented in the script header AND in [`docs/03-runbooks/keycloak-operations.md` § The kcadm-admin pattern](./docs/03-runbooks/keycloak-operations.md). End-to-end script verification deferred to operator-time after the bootstrap UI step. **Phase 9 unblocked** (still gated on F-CLU-11 OpenBao admin auth recovery for the BAO_TOKEN minting workflow, but workload-side SPIFFE-JWT auth path is unaffected).

**Original plan (kept for historical context — superseded by status above):** ⬜ — surfaced by Phase 6b-0 (2026-04-30); ADR-FIRST sequencing required

**Why:** every kcadm-using script in `infrastructure/keycloak/` currently authenticates as a master-realm user (`jaupole` or the now-deleted `bootstrap-admin`) via password+TOTP-concat. **kcadm 26.x has no `--otp` flag**; the password+TOTP-concat trick depends on the master realm's direct-grant flow accepting trailing OTP digits, which is fragile and version-dependent. This came to a head during Phase 6b-0 when the spike script could not authenticate at all and we manually created a `kcadm-spike` service-account client with 6 scoped roles to unblock the spike. Every future kcadm script will hit this same wall.

**Higher-urgency line item — separate from the broader migration:**
- **`infrastructure/keycloak/verify.sh` is broken on Keycloak 26.x.** It uses `--otp` (a flag that does not exist in kcadm 26.x). Phase 3's automated re-verification harness currently does not run. Fix surgically first (drop `--otp`, switch to `client_credentials` via the new `kcadm-admin` once the ADR-first sequencing below is complete), then bundle the same change into the broader migration.

**ADR-FIRST sequencing:**
The `kcadm-admin` client is a long-lived (>24h) credential. CLAUDE.md prohibits long-lived credentials without explicit approval. **Write the ADR documenting the carve-out BEFORE creating the client.** ADR slot is unallocated; check `ls docs/02-decisions/` to claim the next available slot per CLAUDE.md ADR-numbering rules. The ADR must cover:
- Why the credential is necessarily long-lived (operational necessity for kcadm scripts; alternatives considered: per-script user credentials with TOTP — broken on kcadm 26.x; service-account-keystore auth — implementation cost not justified for local edition)
- 90-day rotation cadence (precedent: realm signing keys, also long-lived per ADR-0006)
- Storage in OpenBao (path: `secret/data/keycloak/clients/kcadm-admin`)
- Audit-log strategy: every kcadm-admin authentication produces a Keycloak event; Phase 7 ingestion will surface these as a per-script audit trail
- Rotation runbook reference

**Deliverables (after the ADR):**
- `kcadm-admin` confidential client in master realm with service-account flow only; idempotent kcadm provisioning script at `infrastructure/keycloak/clients/kcadm-admin.sh` (chicken-and-egg: bootstrap is done manually in the UI by the project owner once, then the script can manage subsequent rotation)
- Role review: enumerate every existing kcadm-using script, grant the union of needed roles on `secforge-tenants-realm` and `master-realm` clients (likely-broader than the spike's 6 roles — specifically must add `manage-users` for `realms/create-tenant-test-user.sh`)
- `secret/data/keycloak/clients/kcadm-admin` populated in OpenBao with `client_secret` field
- **Host-side OpenBao access path** — `bao` CLI is currently NOT installed on the WSL host (discovered during Phase 6b-0); kcadm scripts that fetch the secret need a host-side access path. Two options to evaluate in this follow-up: (a) install `bao` CLI on the WSL host as a documented prerequisite, (b) use `kubectl exec` into the openbao pod with a short-lived token. Pick one in the ADR.
- Migration of `infrastructure/keycloak/clients/openbao.sh`, `realms/bootstrap-bff-clients.sh`, `realms/create-tenant-test-user.sh`, `verify.sh` from password+TOTP-concat (or `--otp`) to `--client kcadm-admin --secret <fetched>` auth
- New section in `docs/03-runbooks/keycloak-operations.md` covering the kcadm-admin pattern, rotation procedure, and role-review-when-adding-a-new-kcadm-script discipline
- The legacy `KCADM_USER`/`KCADM_PASSWORD`/`KCADM_TOTP` env-var pattern is removed across the repo

**Verification:**
- All 4 migrated kcadm scripts run successfully under the new auth
- `verify.sh` runs to completion (Phase 3 has working automated re-verification again)
- Rotation runbook exercise: rotate the secret, update OpenBao, re-run a representative script — passes

**See:** ADR (to be written), `docs/03-runbooks/keycloak-operations.md` (to be updated)

**Scheduling:** Scheduled for after Phase 7 completes — decoupled from Phase 7 itself (the original cross-reference from Phase 5 follow-up #3 has been removed). The OIDC CLI redirect URI fix is now Phase 7.0.c (folded into Phase 7), independent of this kcadm-admin work. This work can run any time once Phase 7 is in place; it does NOT require Phase 7b/7c/7d. **Hard sequencing constraint:** must run **before Phase 9** (Hello World End-to-End) — Phase 9's user provisioning (jason / alice / bob seeding in `secforge-tenants`) is the first place every existing kcadm script gets exercised end-to-end, so doing the migration after Phase 9 means re-doing user-provisioning work twice. Critical path: 7 ✅ → 6b-1 → **3 follow-up** → Fix-after-07 → 9.

---

## Phase 4 — Authorization Engine (SpiceDB) *(2 days)*
**Status: ✅ Complete (2026-04-29) — including AuthZEN façade. Image-store toggle resolved; rebuild + re-roll succeeded; all 5 end-to-end AuthZEN evaluations match expected decisions.**

SpiceDB deployed with the three-tier permission schema. AuthZEN façade live and serving.

**Deliverables (all verified by `infrastructure/spicedb/check-permissions.sh`):**
- SpiceDB Operator v1.24.0 + SpiceDB v1.51.1, 1 replica Deployment, Postgres backend over TLS (`sslmode=require`)
- Three-tier ReBAC schema (`user`, `tenant`, `app`, `document`) live in SpiceDB; round-trip validated against the Git source ([ADR-0008](./docs/02-decisions/0008-authz-schema.md))
- Validator tests under `infrastructure/spicedb/tests/` (4 files: owner-edit, viewer-readonly, no-relation-denied, tenant-admin-cascades) all PASS via `zed validate`
- Pre-shared key in K8s Secret `spicedb/spicedb-config` (Phase 5 migrates to OpenBao SPIFFE-bound dynamic credential)
- Phase 4.4 seed: 7 baseline relationships (tenant:helloworld, app:helloworld-app, document:welcome with jason owner, alice viewer)
- Phase 4.5 outcomes: 11 of 11 CheckPermission expectations PASS (7 baseline + 4 cascade), ZedToken read-your-writes consistency verified with `--consistency-at-least`
- mTLS gRPC on port 50051 via cert-manager (`spicedb-grpc-tls` Cert from mkcert ClusterIssuer); ClusterIP only, never via Ingress
- Self-dispatch loop on port 50053 over TLS (`dispatchUpstreamCaPath: /tls/ca.crt`); permitted by `allow-spicedb-self-dispatch` NetworkPolicy
- 7 NetworkPolicies in `spicedb` ns: default-deny ingress + 5 targeted ingress allows + Postgres ingress + egress
- SPIRE-issued SVID `spiffe://secforge.local/ns/spicedb/sa/spicedb` mounted via SPIFFE-CSI
- Pod hardening: PSS=restricted, drop ALL caps, non-root UID 65532, seccomp RuntimeDefault, readOnlyRootFilesystem (Patch 1: Deployment, Patch 2: migration Job — both required to satisfy Kyverno's `enforce-pod-security-restricted`)
- Audit log structured-JSON to STDOUT
- AuthZEN façade live in `app` namespace, 2/2 replicas Ready, audit log emits one structured-JSON line per evaluation. End-to-end smoke test through the façade's `POST /access/v1/evaluation` endpoint passes all 5 expected outcomes (jason view/edit ALLOWED, alice view ALLOWED, alice edit DENIED, bob view DENIED) and `/readyz` returns 200
- AuthZEN façade source: `apps/authzen-facade/` (~200 LoC Go, AuthZEN 1.0 evaluation handler, multi-stage Dockerfile to a distroless final image, K8s manifests for SA + 2-replica Deployment + Service + 2 NetworkPolicies)
- In-cluster `registry:2` deployed in `registry` namespace (PSS-restricted; retained for future cross-pod image distribution though the active pull path is now containerd-shared via Docker Desktop toggle)

**Documentation:**
- Architecture: [docs/01-architecture/02-authorization.md](./docs/01-architecture/02-authorization.md)
- ADR: [docs/02-decisions/0008-authz-schema.md](./docs/02-decisions/0008-authz-schema.md)
- Runbook: [docs/03-runbooks/spicedb-operations.md](./docs/03-runbooks/spicedb-operations.md)
- Schema source-of-truth: [infrastructure/spicedb/schema.zed](./infrastructure/spicedb/schema.zed)
- Validator tests: [infrastructure/spicedb/tests/](./infrastructure/spicedb/tests/)

**Deviations from the original phase prompt** (all documented inline):

- ADR file numbered **0008** not 0004 (0004 is `kyverno-audit-mode`).
- **Migration Job needs its own PSS-restricted patch** in `spec.patches` (in addition to the Deployment patch) — Kyverno's `enforce-pod-security-restricted` blocks the operator's migration Job otherwise.
- **`dispatchClusterEnabled: "true"`** with `dispatchUpstreamCaPath: /tls/ca.crt` — the operator wires `DispatchUpstreamAddr` regardless of this flag; setting `false` leaves the upstream pointed at a non-existent dispatch server and CheckPermission times out. With `true`, the dispatch server is on, the pod self-dispatches, and the CA path is needed because dispatch traffic is mTLS over the same cert as the public gRPC port.
- **NetworkPolicy selector** uses `authzed.com/cluster: spicedb` rather than `app.kubernetes.io/name` — the operator labels runtime pods with `spicedb-spicedb` (concatenated) but migration-Job pods with `spicedb`, so the cluster-name label is the only reliable selector across both.
- **`allow-zed-admin-to-spicedb` NetworkPolicy** for in-namespace `zed` CLI one-shot pods (label `role: zed-cli-oneshot`); they're intentionally NOT labeled `authzed.com/cluster: spicedb` so the egress policy doesn't apply.
- **`allow-spicedb-self-dispatch`** allows port 50053 ingress from same-cluster pods (the dispatch loop) and a corresponding egress entry; neither was in the original spec.
- **AuthZEN façade requires Docker Desktop containerd image-store toggle** to be enabled (Settings → General → "Use containerd for pulling and storing images"). Without it, `imagePullPolicy: Never` returns ErrImageNeverPull because docker daemon's image store is separate from K8s containerd's. After the toggle, `docker build` writes directly to containerd's K8s namespace and the Deployment pulls cleanly. Resolved 2026-04-29.
- **Cosign image signing of the façade still deferred** to a future supply-chain phase (the policy is in Audit mode — ADR-0004 — and unsigned images deploy with warnings). Re-tackle alongside the cluster-internal CI pipeline.

**See:** [docs/05-claude-code-prompts/phase-04-spicedb.md](./docs/05-claude-code-prompts/phase-04-spicedb.md)

---

## Phase 5 — Secrets Management (OpenBao) *(2-3 days)*
**Status: ✅ Complete (2026-04-30) — initial root token revoked, OIDC admin login working, end-to-end SPIRE→JWT→OpenBao test workload passes.**

OpenBao deployed with the production-realistic two-instance Transit auto-unseal pattern. Seal-OpenBao (Shamir 5/3) holds the unseal key; main OpenBao (3-replica Raft) auto-unseals from it.

**Deliverables (all verified):**
- **openbao-seal** — single-replica Shamir-sealed OpenBao in `openbao` ns, file storage on PVC, runs only the Transit secrets engine. Manually unsealed via `infrastructure/openbao/unseal-seal.sh` after every Docker Desktop restart.
- **main openbao** — 3-replica Raft cluster, integrated storage, auto-unseals via the seal-OpenBao's Transit endpoint. Initial root token **revoked** after OIDC verified.
- **Auth methods**:
  - `kubernetes/` — used by `admin-break-glass` role (1h TTL admin) and future runbook helpers
  - `oidc/` — federated to Keycloak `platform` realm via the `openbao` confidential client (provisioned via UI; kcadm script committed at `infrastructure/keycloak/clients/openbao.sh` for future bootstraps); `admin` role currently binds on `preferred_username=jason.upole` (interim — see follow-up below)
  - `jwt/` — bound to SPIRE OIDC discovery provider for workload SPIFFE-ID auth; roles for `helloworld-bff` and `authzen-facade` mapped to the `helloworld-bff` policy
- **Secrets engines**:
  - `secret/` (kv-v2) — static secrets per app; user namespaces under `secret/users/<name>/*`
  - `database/` — Postgres source `secforge-app` against `secforge-app-db`, with roles `helloworld-app-readwrite` (1h TTL, 24h max) and `helloworld-app-readonly`. Bootstrap creds rotated immediately so OpenBao owns them.
  - `transit/` — `pii-encryption` aes256-gcm96 key for app-level encryption-as-a-service
- **Policies** (`infrastructure/openbao/policies/`): `admin` (full), `reader` (per-user KV), `helloworld-bff` (scoped to KV path + dynamic Postgres + Transit)
- **Audit logging** — config-only HCL stanza (OpenBao 2.x removed the API path); STDOUT JSON, every operation logged
- **End-to-end test (Phase 5.9)** — Job pod with SA `helloworld-bff` runs spiffe-helper init container to fetch JWT-SVID with audience=openbao, then a Python container that authenticates to OpenBao, reads a static KV, and mints a dynamic Postgres credential. ALL CHECKS PASSED on first deploy.
- **Migrated secrets (Phase 5.10)** — SpiceDB pre-shared key + 4 BFF private_key_jwt keypairs replicated into `secret/data/spicedb/preshared-key` and `secret/data/keycloak/clients/<id>`. K8s Secrets stay authoritative for consumers until Phase 6 wires Vault Secrets Operator (or direct API).
- **Ingress** — `https://bao.secforge.local` with source-IP allowlist (`172.19.0.0/16,127.0.0.1/32`); chart's HelmRelease Ingress disabled because it points at `<release>-active` Service (which has no endpoints). Replaced by `infrastructure/openbao/08-ingress.yaml` pointing at the regular `openbao` Service.
- **Pod hardening** — PSS=restricted, drop ALL caps, non-root UID 100, seccomp RuntimeDefault, readOnlyRootFilesystem (with /tmp emptyDir for Quarkus). SPIFFE-CSI volumes mounted; SVIDs `spiffe://secforge.local/ns/openbao/sa/{openbao,openbao-seal}`.
- **Resource quota** — `openbao` ns bumped from 2/2Gi to 4/8Gi to fit operator + 4 OpenBao pods + transient CNPG.

**Documentation:**
- Architecture: [docs/01-architecture/05-secrets-management.md](./docs/01-architecture/05-secrets-management.md)
- ADR: [docs/02-decisions/0009-openbao-seal-strategy.md](./docs/02-decisions/0009-openbao-seal-strategy.md)
- Runbooks: [openbao-seal-unseal.md](./docs/03-runbooks/openbao-seal-unseal.md), [openbao-recovery.md](./docs/03-runbooks/openbao-recovery.md)
- Reference: [openbao-policies.md](./docs/06-reference/openbao-policies.md)

**Deviations from the original phase prompt** (all documented inline):

- ADR file numbered **0009** not 0005 (0005 was already used by `spire-architecture-local`).
- **OpenBao OSS doesn't support `token_env_var` for transit seal** (Vault Enterprise only). Worked around by rendering the `seal "transit"` block at apply-time into a Secret `openbao-seal-block`, mounted alongside the chart's main config and merged via `extraArgs: -config=`. Token never lands in any ConfigMap or rendered Helm manifest.
- **OpenBao 2.x removed `bao audit enable` API**; audit must be configured in HCL. Format: `audit { type="file" path="stdout/" options={ ... } }`.
- **Chart's Ingress always returns 503** — its hardcoded `<release>-active` Service has no endpoints. Disabled the chart's Ingress (`server.ingress.enabled: false`); shipped `08-ingress.yaml` pointing at the regular `openbao` Service.
- **`hostAliases` for `auth.secforge.local`** — Docker Desktop forwards pod DNS to the host, which has `auth.secforge.local → 127.0.0.1` in `/etc/hosts`, so OpenBao would talk to itself for OIDC discovery. Pods now have a hostAlias mapping `auth.secforge.local` (and admin/bao) to ingress-nginx ClusterIP `10.96.97.16`.
- **SPIRE-issued SVID DNS SANs** — added explicit `dnsNameTemplates` to a new `secforge-spire-oidc-discovery-provider` ClusterSPIFFEID so OpenBao's Go-stdlib TLS verifier can match the discovery provider's hostname. Default ClusterSPIFFEID has `autoPopulateDNSNames: false`.
- **OIDC `admin` role binds on `preferred_username=jason.upole`** instead of `realm_access/roles=platform_admin`. Keycloak's `roles` scope is set to Default on the openbao client and the `realm roles` mapper has Add-to-ID-token + userinfo enabled, but `realm_access.roles` still doesn't appear in OpenBao's captured claims. Captured as a follow-up; binding works as-is for the single-developer setup.
- **OpenBao chart uses `OnDelete` update strategy** — Helm upgrades don't roll the StatefulSet pods automatically. Documented; `apply-main.sh` rolls them manually.
- **Spiffe OIDC Discovery Provider** — enabled in the SPIRE Helm chart (was off by default in Phase 2); needed by OpenBao's `auth/jwt/config` to validate JWT-SVID issuer.

**Known follow-ups:**
1. Fix `realm_access.roles` claim plumbing through Keycloak → OpenBao OIDC userinfo so the admin role can re-bind to the realm-role claim (allowing additional `platform_admin` users to inherit admin without per-user binding). **Scheduled as Phase 7.0.b** — once Loki + Wazuh are ingesting Keycloak and OpenBao logs, we'll have the structured event data to debug the userinfo response format properly. Sequencing constraint: must run AFTER Phase 7.4 (Loki) goes live. Low impact until a second admin user is added. **Re-evaluate priority if any of:** (a) a second person needs admin on this platform, (b) Keycloak emits a security advisory affecting the userinfo endpoint, (c) Phase 8 (Teleport) starts, since it also depends on realm-role propagation, (d) 90 days elapse since 2026-04-30 (i.e., by 2026-07-29) — at which point bring forward regardless of other triggers. **Phase 7.0.b debug session 2026-04-30 — DEFERRED (NOT FIXED, evidence gathered):** Keycloak's Evaluate tool (Clients → openbao → Client scopes → Evaluate) confirms `realm_access.roles[platform_admin]` IS present in the rendered userinfo response, ID token, AND access token outputs. Mapper config is correct (`realm roles` mapper with `Add to userinfo: ON`, claim path `realm_access.roles`, multivalued). Yet OpenBao 2.5.3 consistently reports `claim "realm_access/roles" is missing` even with `oidc_scopes: [openid, profile, email, roles]` AND `bound_claims: {"realm_access/roles": ["platform_admin"]}` (per HashiCorp/OpenBao docs the `/` separator is the correct nested-claim notation). Conclusion: the defect is **OpenBao-side**, not Keycloak. OpenBao's plugin either isn't calling userinfo with the right Authorization to surface the scope-gated claim, has a nested-claim parsing bug, or isn't merging userinfo claims into the validation set. Worth filing upstream against [openbao/openbao](https://github.com/openbao/openbao). The `preferred_username` workaround in `infrastructure/openbao/configure-auth-oidc.sh` (and the matching role_attribute_path in `infrastructure/observability/01-kube-prometheus-stack-values.yaml` for Grafana) remain in place. Defer per the 90-day fallback trigger 2026-07-29 — at that point either the upstream bug is fixed, or we need to switch to a different bound-claim path (e.g., `groups_claim` field which has a special handler).
2. Decommission the now-idle `secforge-openbao-db` CNPG cluster (Phase 1 created it for Postgres-backed OpenBao storage; we use Raft instead). **Scheduled for the start of Phase 6** — bundle with the Phase 6.0 housekeeping step below, so the cluster is clean before we layer Istio on top. Single-command `kubectl delete cluster secforge-openbao-db -n openbao`.
3. **OIDC `admin` role missing CLI redirect URI** (surfaced 2026-04-30 during Phase 6.10b Step 2). The `admin` role's `allowed_redirect_uris` only lists UI callbacks (`https://bao.secforge.local/...`); the bao CLI's local listener (`http://localhost:8250/oidc/callback`) is not whitelisted, so `bao login -method=oidc` fails. Worked around in Step 2 by getting the admin token via the UI. Fix: add the CLI listener URI to BOTH (a) the OpenBao role's `allowed_redirect_uris` in `infrastructure/openbao/configure-auth-oidc.sh`, and (b) the Keycloak `openbao` client's Valid Redirect URIs in `infrastructure/keycloak/clients/openbao.sh`. Effort: ~30 min. **Scheduled as Phase 7.0.c** — folded into the Phase 7 carry-ins block alongside the SPIFFE-CSI startupProbe and `realm_access.roles` debug.
4. ~~**SpiceDB datastore_uri is a static copy**~~ ✅ **Resolved 2026-05-02 (Phase 7d.2)** with one structural caveat captured in [ADR-0023](./docs/02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md). The original "VaultStaticSecret → VaultDynamicSecret" plan was structurally blocked: SpiceDB Operator's `secretName` requires a single Secret holding both `preshared_key` and `datastore_uri`, and VSO can't compose a single rendered Secret from two OpenBao sources. Phase 7d.2 chose **Path B**: keep the VaultStaticSecret, add a 12h CronJob (`spicedb-datastore-refresher` in spicedb ns) that re-populates `secret/data/spicedb/config` from the database engine + static PSK. Net effect: the original "CNPG password rotation desyncs the value" problem is closed at the consumer level — SpiceDB sees a Secret that's never older than the dynamic-cred max_ttl. The static migration script `infrastructure/vault-secrets-operator/migrate-datastore-uri-to-openbao.sh` was archived. CNPG-side password rotation still requires an operator re-bootstrap of OpenBao's connection root credential (procedure in `docs/03-runbooks/spicedb-operations.md § Recover from CNPG-side spicedb user password rotation`).
5. **`infrastructure/spicedb/check-permissions.sh` parser flake on zed version warnings** (surfaced 2026-04-30 during 6.10b Step 3 verification). When zed's upstream-update HTTP check succeeds, it prepends a JSON warning line to stdout (`{"level":"warn","this-version":"v1.51.1","latest-released-version":"v1.52.0",...}`); the script's parser grabs that line as the result instead of the actual permission decision, producing false-positive failures. The cutover itself was verified end-to-end via AuthZEN's HTTP API as a workaround. Fix: parse with `jq` to extract `decision`/`relationship`/`token` fields specifically rather than relying on first-line. Or pass `--quiet` / silence the version check via env var if zed supports one. Effort: ~30 min. Low priority — this is a tooling robustness issue, not a security/correctness one.
6. **SPIFFE-CSI cold-boot race.** Every Docker Desktop restart causes a 60–90s window where the `csi.spiffe.io` driver isn't yet registered with kubelet, while OpenBao StatefulSet pods (the 4 SPIFFE-CSI consumers needing the fix: `openbao-0/1/2` + `openbao-seal-0`) try to mount the SPIFFE-CSI volume. Pods enter exponential backoff (up to 5 min between restart attempts), and even when they retry, the JWT-SVID minted by the spiffe-helper init container has 5-min TTL and may have already expired before the main container starts — a cascade of mount-fail → backoff → SVID-expired → CrashLoop. **Note (Fix-after-07 §B.1 secondary verification, F-CLU-1):** `helloworld-bff` and `authzen-facade` already carry HTTP startupProbes (`/ready` and `/readyz`), so they self-heal via kubelet's retry without needing this fix; only the 4 OpenBao pods were affected. Today's manual workaround was: `kubectl delete pod` per-affected-OpenBao-pod after boot. **Resolved via the `wait-for-spiffe-csi` init container** (Phase 7.0.a roll, 2026-05-01) which blocks main-container start until `/spiffe-workload-api/spire-agent.sock` exists — structural fix for the "why" (no exponential backoff, no JWT-SVID expiry mid-retry). Chart 0.27.2 doesn't expose `server.startupProbe` with the exec-command form needed to test for the socket; the init container is the equivalent. Soak target: zero post-boot manual deletes for 7 consecutive days, tracked via the platform-health Grafana dashboard's pod-restart panel — runs as background-monitoring after Phase 7's full closure, not phase-blocking. Defense-in-depth alternatives (PriorityClass for SPIRE/CSI pods) documented in [docs/03-runbooks/spire-rotation.md § cold-boot race](./docs/03-runbooks/spire-rotation.md). Background: this is a local-only race — cloud-edition K8s schedulers and DaemonSet rollout ordering avoid it, so the fix only needs to live in local-edition manifests.

**See:** [docs/05-claude-code-prompts/phase-05-openbao.md](./docs/05-claude-code-prompts/phase-05-openbao.md)

---

## Phase 6 — Service Mesh and BFF *(4-5 days)*
**Status: ✅ Complete (2026-04-30)** — Part 0 ✅, Part A ✅ (Checkpoint A passed 2026-04-29), 6.5 BFF design ✅, 6.6–6.8 BFF implementation/build/deploy ✅, **6.9 partially verified (2026-04-30)**: BFF starts cleanly, OpenBao bootstrap succeeds, `/healthz` 200, `/ready` 200, `/login` issues correct PAR redirect to Keycloak (`request_uri=urn:ietf:params:oauth:request_uri:...`, `client_id=helloworld-bff`, `secforge-tenants` realm). Full browser login + post-callback cookie/DPoP/logout checks **deferred to Phase 9** (which seeds the jason/alice/bob users in `secforge-tenants` and adds a real backend so `/api/*` returns 200 instead of 502 — duplicating user provisioning here was judged busywork). **6.10 ✅ (2026-04-30)** — security headers verified end-to-end. **6.10b ✅ (2026-04-30)**: VSO 1.3.0 installed; per-namespace VaultStaticSecrets render `spicedb/spicedb-config-vso` and `app/authzen-facade-spicedb-creds-vso` from OpenBao via K8s auth; SpiceDB + AuthZEN cut over with end-to-end CheckPermission verified (`{"decision":true/false}`); 5 original K8s Secrets deleted (spicedb-config + authzen-facade-spicedb-creds + 4 BFF bff-jwt-*); BFF restarted clean from OpenBao alone; ADR-0015 Accepted. Three follow-ups carried forward in this document (BFF rotation, OIDC CLI redirect URI, `datastore_uri` static-copy → database-engine). **6.11 ✅ (2026-04-30)** — docs updated: `04-bff-pattern.md` (ADR-0015 reference + runbook link), `05-secrets-management.md` (VSO is now deployed, not deferred), `bff-operations.md` (created), `spicedb-operations.md` (Secret name corrected to `spicedb-config-vso`), runbook README index updated.

Istio Ambient mode (with Istio's built-in CA — SPIRE-as-CA deferred to 6.2b, see follow-ups). The BFF service. Also: cut over Phase 5.10's migrated secrets so OpenBao becomes authoritative.

**Phase 6.0 housekeeping (do first, ~30 min):**
- Decommission idle `secforge-openbao-db` CNPG cluster (Phase 5 follow-up #2): `kubectl delete cluster secforge-openbao-db -n openbao` and remove its PVCs.
- Confirm Phase 5.10 secrets are still in sync between K8s Secrets and OpenBao before Phase 6.X removes the K8s copies.

**Deliverables:**
- Istio Ambient deployed (built-in Citadel CA; ztunnel + waypoints + istio-cni)
- AuthorizationPolicy with default-deny and SPIFFE-ID-based allows (interim trust domain `spiffe://cluster.local/...`; rewritten to `spiffe://secforge.local/...` in 6.2b)
- BFF service in Go (~300 lines): OAuth 2.1 with PAR + DPoP, Valkey session, opaque cookie out, JWT in
- Strict CSP and security headers operational
- Health/readiness probes
- **OpenBao becomes the sole source of truth for Phase 5.10 migrated secrets**: BFF and SpiceDB consumers fetch directly from OpenBao via SPIFFE-bound auth (Vault Secrets Operator OR direct API at startup — pick one in the architecture doc). The K8s Secret copies (`spicedb/spicedb-config` PSK, `app/bff-jwt-*`) are **deleted** as part of the cutover, not left behind. Without this, rotating either secret risks drift.

**Known follow-ups:**
1. **Phase 6.2b — Cut Istio over to SPIRE as external CA.** Replace Istio's built-in Citadel with SPIRE-issued workload SVIDs so the mesh and the rest of the platform speak one trust domain (`spiffe://secforge.local/...`). Until this lands, ztunnel-to-ztunnel mTLS uses `spiffe://cluster.local/...` while OpenBao/SpiceDB auth continues to use `spiffe://secforge.local/...`. **Scheduled as Phase 7c** (paired with PeerAuthentication STRICT — see follow-up #2) — Loki + Tempo from Phase 7 will make the cutover observable as it lands. Cloud migration cannot ship with two trust domains; this is the latest-acceptable boundary. Effort estimate: 1-2 days. See [ADR-0010](./docs/02-decisions/0010-istio-ambient-vs-sidecar.md) for the deferral rationale.
2. **PeerAuthentication tighten to STRICT.** 6.2 ships PERMISSIVE (so non-mesh callers — ingress-nginx, openbao→postgres, kubelet probes — can reach ambient pods). Tightening becomes safe once every legitimate caller is mesh-resident or covered by an explicit AuthorizationPolicy ALLOW. **Scheduled as Phase 7c** (paired with the SPIRE-as-CA cutover — they share a change window because STRICT only becomes safe under the unified trust domain).
3. **Per-session DPoP keys for BFF (cloud).** Phase 6.6 ships per-pod DPoP keys + `replicas: 1` (see [docs/01-architecture/04-bff-pattern.md](./docs/01-architecture/04-bff-pattern.md)). Cloud edition needs per-session keys persisted in Valkey, encrypted with an OpenBao Transit KEK, so multi-replica BFF works. **Scheduled for pre-migration hardening.** Effort: 1 day; mostly Valkey schema + OpenBao Transit binding.
4. **Back-channel logout (OIDC SLO) for BFF.** `/backchannel-logout` endpoint accepting Keycloak logout tokens. Required when "admin force-logs-out a user" or "session-revoke event from Keycloak" become real operational needs. Scheduled when first concrete use case appears.
5. **BFF code-size review (post-Phase 9).** Phase 6.6 shipped at ~1,277 LoC across `apps/helloworld-bff/*.go`, over the prompt's ~300-500 ceiling. Tradeoff was deliberate: prioritize 1:1 mapping to design-doc decisions over hitting the line budget, accepting that some files (`oidc.go` 270, `proxy.go` 325) will become refactor candidates once Phase 9 surfaces which pieces are actually load-bearing vs. defensible-but-unused. **Don't refactor for size now** — wait until the Hello World end-to-end flow has exercised the code paths. Phase 9 / Phase 10 review pass: identify dead branches (e.g., revocation paths that are never hit, OIDC discovery fields that aren't consumed), consolidate the OIDC client against `golang.org/x/oauth2` if integration tests prove it carries weight, and update PLAN.md if the LoC ceiling becomes a real constraint.
6. **Cosign image signing for `helloworld-bff` and `authzen-facade`.** Phase 6.7 deferred Cosign signing to match the existing project posture: Kyverno runs `verify-image-signatures` in Audit (per [ADR-0004](./docs/02-decisions/0004-kyverno-audit-mode.md)), `authzen-facade` (Phase 4) shipped unsigned, and the supply-chain pipeline (key custody + signing flow + Kyverno flip-to-Enforce) is its own future phase. Re-tackle as a single thread: create the signing key (consider Cosign keyless via in-cluster OIDC since GitHub OIDC isn't available locally), sign both images, then flip Kyverno to Enforce. Trivy + Grype are already wired into `apps/helloworld-bff/build.sh` (CRITICAL gate); SBOM lands in `apps/helloworld-bff/sbom/`.
7. **`authzen-facade` dependency refresh.** Phase 6.7 added a committed `go.sum` and switched the Dockerfile to deterministic `go mod download` (matching `helloworld-bff`), but did NOT bump dependencies. `go get -u ./...` against the existing graph hits an ambiguous-import conflict between `cloud.google.com/go v0.26.0` and `cloud.google.com/go/compute/metadata v0.9.0`, both pulled in by `grpc-ecosystem/go-grpc-middleware/auth.test` (test-only). Resolving requires explicit `replace` directives or an upstream fix. Worth doing alongside the Cosign work above (matched cadence).

**Optional parallel work (run any time during Phase 6, no dependency on BFF):**
- **Phase 6b-0 token-exchange spike** *(2 hours)* — de-risk Keycloak's preview `token-exchange` feature before Phase 6b-1 commits to RFC 8693. Optional in scheduling (run now, in Phase 6b, or skip entirely), **not** optional in outcome — the spike either confirms GO and Phase 6b-1 implements RFC 8693, or returns NO-GO and Phase 6b-1 falls back to "audience-at-login." Either path produces a working Phase 6b-1; the spike just decides which. Running it during Phase 6 means a NO-GO finding could shape the BFF's token-handling code before it's frozen, saving rework. See [phase-06b-0-token-exchange-spike.md](./docs/05-claude-code-prompts/phase-06b-0-token-exchange-spike.md).

**See:** [docs/05-claude-code-prompts/phase-06-istio-bff.md](./docs/05-claude-code-prompts/phase-06-istio-bff.md) · 6.10b extracted to [phase-06.10b-vso-and-secret-cleanup.md](./docs/05-claude-code-prompts/phase-06.10b-vso-and-secret-cleanup.md) (decision pattern: [ADR-0015](./docs/02-decisions/0015-secret-distribution-pattern.md))

---

## Phase 6b-0 — Token-exchange spike *(2 hours, ran 3+)*
**Status: ✅ Complete (2026-04-30) — NO-GO. See [ADR-0012](./docs/02-decisions/0012-token-exchange-feasibility.md).**

**Outcome:** RFC 8693 token-exchange on Keycloak 26.3.3 is too unstable to build the api-auth library against. Phase 6b-1 pivots to **audience-at-login** with documented limitations.

**Findings (full detail in ADR-0012 §"Findings"):**
1. `token-exchange` feature requires `admin-fine-grained-authz` to be enabled in tandem; not standalone. Phase prompt's single-line `--features=token-exchange` instruction was materially incomplete.
2. Both `admin-fine-grained-authz` (v1) and `admin-fine-grained-authz:v2` are accepted in `KC_FEATURES` env and confirmed by `kc.sh show-config`, but neither satisfies runtime gating at `ClientResource.getManagementPermissions:709` ("Feature not enabled" thrown anyway).
3. Per-pair token-exchange authorization could not be configured within reasonable spike time bounds. The "preview" status is materially load-bearing — surface is moving, runtime gating is inconsistent with config parsing, errors are not actionable.
4. Independent fragility: client `private_key_jwt` auth itself failed with `invalid_client: Unable to load public key` using the documented `jwt.credential.public.key` + `use.jwks.string=false` layout. Format appears to have changed in 26.x.

**Cluster-state changes committed by this NO-GO:**
- `token-exchange` and `admin-fine-grained-authz` removed from Keycloak CR's `features.enabled` (per ADR-0012's blast-radius reasoning); CR now lists only `recovery-codes` and `dpop`
- Spike clients `spike-bff`, `spike-api`, `kcadm-spike` deleted; `/tmp/secforge-spike/` removed; `KCADM_CLIENT_SECRET` cleared
- Spike scripts `infrastructure/keycloak/spike-token-exchange.sh` and `spike-token-exchange-test.sh` retained in-tree as historical artifacts (not part of any normal workflow)

**See:** [ADR-0012](./docs/02-decisions/0012-token-exchange-feasibility.md), [phase-06b-0 spike doc](./docs/05-claude-code-prompts/phase-06b-0-token-exchange-spike.md) (annotated with NO-GO outcome).

---

## Phase 6b-0 follow-up — Re-evaluation triggers
**Status: ⬜ Tracked indefinitely**

The Phase 6b-0 NO-GO is not permanent. Re-spike token-exchange feasibility on any of these triggers (per ADR-0012 §"Re-evaluation criteria"):

- **Keycloak 26.4+ release** if release notes specifically address `token-exchange` and/or `admin-fine-grained-authz` stabilization (graduation from preview, runtime gating fixes, documented dependency requirements)
- **Cloud-edition Keycloak migration** — managed Keycloak services may pin to a more stable preview-feature surface, or have validated the token-exchange path
- **Compliance-driven actor-chain audit requirement** — if a future Phase requires per-call actor identity with cryptographic non-repudiation that the audience-at-login model cannot satisfy
- **Library encounters API-shape needs that audience-at-login can't model** — e.g., A→B→C call chain where C must verify B's authority independently of A; new downstream API not anticipated at session-start time

When any trigger fires, the path is: re-enable `token-exchange` and `admin-fine-grained-authz` in the Keycloak CR, re-run the spike protocol from Phase 6b-0 (scripts retained), and update ADR-0012 with a "Re-evaluation 2026-MM-DD" section recording the new outcome.

---

## Phase 6b-1 — API Auth Pattern *(2 days)*
**Status: ✅ Complete (2026-05-01)** — six signed commits (`d9996be` skeleton → `a6ce8d1` middleware → `07f86d9` client + Q3 verification → `06c87ef` audit → `db786fc` BFF wiring → commit-6 verification + docs + flip). `apps/lib/api-auth/` shipped per [ADR-0014](./docs/02-decisions/0014-api-auth-library-design.md) with all three primary types (Middleware, Client, Audit); `helloworld-bff` rewired as the reference consumer. 84.2% line coverage, `-race -count=10` stability passes. Q3 live curl verification deferred to an operator-runnable script at [`infrastructure/lib/api-auth/verify-q3-refresh.sh`](./infrastructure/lib/api-auth/verify-q3-refresh.sh) (full curl flow needs kcadm + a live user session); library handles both Q3 outcomes regardless. **LoC budget note:** prompt's "150-300 LoC" target proved unrealistic against the spec's 17-step inbound + JWKS cache + DPoP + RFC-7523 client_assertion + Q4 audit schema — library landed at ~1000 LoC of production code. Trade-off documented in commit `07f86d9`. **Runbook:** [`docs/03-runbooks/api-auth-library.md`](./docs/03-runbooks/api-auth-library.md). **Arch doc:** [`docs/01-architecture/06-api-pattern.md`](./docs/01-architecture/06-api-pattern.md). **Phase 9 unblocked** (still gated on Phase 3 follow-up + clean cluster state).

**Prerequisites:** Phase 6 ✅ · Phase 7 ✅ · [ADR-0012 § Resolution (2026-05-01)](./docs/02-decisions/0012-token-exchange-feasibility.md#resolution-2026-05-01) ✅ · [ADR-0014](./docs/02-decisions/0014-api-auth-library-design.md) ✅.

Inbound API auth as a reusable Go library. Phase 6 shipped browser→BFF (Tier 1); 6b-1 ships BFF→backend-API (Tier 2). Self-contained: Phase 9 could ship against just this if 6b-2 slipped.

**Deliverables:**
- **`apps/lib/api-auth/` Go module** (~150-300 LoC): `Middleware` (inbound JWT + DPoP validation), `Client.MintTokenForAudience` (outbound — audience-at-login refresh-with-expanded-scope; Q3 try-expand-fallback-relogin), `Audit.LogHop` (Q4 SPIFFE+request-id schema). API surface fixed by ADR-0014. **Does NOT include `ExchangeFor` or any RFC 8693 client** — NO-GO per ADR-0012.
- **Architecture doc** `docs/01-architecture/06-api-pattern.md`: narrative description of the audience-at-login model; cross-link to ADR-0012 + ADR-0014.
- **One runbook**: `docs/03-runbooks/api-auth-library.md` — how to use the library, common mistakes, troubleshooting.
- **Keycloak per-API audience scopes** configured via idempotent kcadm scripts at `infrastructure/keycloak/clients/` (Path A pattern from Session 3 memory). One Optional scope per backend API; BFF clients request the union of needed scopes at login per Q2's static-config decision.
- **`helloworld-bff` updated** as the reference consumer: imports `apps/lib/api-auth/`, replaces manual JWT+DPoP code path with library calls, declares `BFF_AUDIENCE_LIST` env var.
- **10-minute Keycloak curl verification** during library implementation to confirm Q3 outcome (a) vs (b) — recorded verbatim in ADR-0014 § "Observed Q3 behavior (2026-05-01)".
- **Phase 9 prompt updated** to mandate the library.

**Verification:**
- Library unit tests pass with `-race -count=10`; ≥ 80% line coverage.
- `helloworld-bff` rebuild + redeploy; Phase 6 login smoke test still green.
- 2-hop integration test (BFF → AuthZEN-facade) produces two log lines in Loki sharing one `request_id`; sort by `hop_index` reconstructs the chain.

**Re-evaluation hook:** when any Phase 6b-0 follow-up trigger fires (see [Watching briefs](#watching-briefs)), the library's outbound path may change to add token-exchange support. The current `Client` design isolates the refresh logic so a future `ExchangeFor` could be added without rewriting `ValidateInbound`.

**See:** [docs/05-claude-code-prompts/phase-06b-api-pattern.md](./docs/05-claude-code-prompts/phase-06b-api-pattern.md) — runnable prompt; the four spec sections + curl verification Q3 are all there.

---

## Phase 6b-2 — Outbound Secrets Pattern + Guardrails *(2 days)*
**Status: ✅ Complete (7 of 7 commits landed, 2026-05-02 Session 5)**

| # | Hash | What |
|---|---|---|
| 1a | `aa10402` | ADR-0013 stub → Accepted (10 mandates) |
| 1b | `f82700a` | `apps/lib/secrets/` outbound extension (398 LoC, 88.7% cov) |
| 2  | `9803725` | `apps/lib/errreport/` scrubber + no-op sink (225 LoC, 89.7% cov) |
| 3  | `af152ea` | `templates/app-repo/` skeleton (9 files) + Trivy `--scanners vuln,secret` flip |
| 4  | `41e27d1` | Kyverno admission (2 ClusterPolicies, 9/9 fixtures) + `apps/security-events-collector/` (67.3% cov) + `legacy-env-warner` CronJob |
| 5  | `f549775` | BFF outbound-Client + ScrubbingReporter wire-in + `/admin/test-outbound-secret` debug endpoint (feature-gated) + AuthZEN ADR-0015 cross-ref comment |
| 6  | _(this session)_ | Closeout — `infrastructure/secrets-guardrails/verify/` (8 scripts + run-all.sh) + 6 runbooks under `docs/03-runbooks/` (secrets-library, migrate-env-to-openbao, new-app-bootstrap, secrets-guardrails-verification, secrets-guardrails-monitoring, ci-secrets-check) + CLAUDE.md no-`.env` bright-line rule + Phase 10.{N}.5 updated with real library API + runbook chain |

**Operator-time prerequisites before exercising the live cluster (not LLM tasks):**
- Provision `security-events-collector` and `security-events-ci` Keycloak clients (mint via `kcadm-admin` per ADR-0022)
- Pre-populate `secret/apps/helloworld-bff/test api_key=<any-non-secret-test-value>` for commit 5's debug endpoint
- Apply `apps/security-events-collector/deploy/` after Keycloak clients exist
- Apply `infrastructure/kyverno/policies/{no-secret-shaped-env,legacy-secret-env-expiry}.yaml`
- Run `bash infrastructure/secrets-guardrails/verify/run-all.sh` (offline) and `LIVE=1 bash …` (live cluster) — record outcomes in PLAN.md follow-ups

**Known follow-ups (deferred, not blocking):**
- Inbound M2M / Tier 5 — third-party access to our APIs (OAuth 2.1 client_credentials with private_key_jwt). Out of scope for 6b-2; lands the first time we actually need it.
- Hardened-mode default flip across all in-cluster apps — ADR-0013 § Hardened-mode rollout plan; revisited at pre-AWS-migration.
- AWS-key prefix support in the DefaultScrubber — ADR-0013 § Re-evaluation triggers; file when it bites in production.
- AuthZEN migration from VSO-shaped to direct-API — ADR-0015 § Open question; revisited when AuthZEN's load profile demands rotation faster than VSO's 60s refresh.
- Phase 7b Promtail/Loki/Grafana wire-up of the JSON-line event stream the collector emits today.

<!-- ============================================================ -->
<!-- END RESUME-NEXT-MORNING marker                               -->
<!-- ============================================================ -->

The `.env`-killer. Outbound third-party credentials (Stripe, OpenAI, SendGrid, SAM.gov, etc.) live in OpenBao and are fetched via SPIFFE-JWT auth at runtime. Self-contained: needs no inbound auth work.

**Deliverables:**
- **`apps/lib/secrets/` Go module** (~100-150 LoC): SPIFFE-JWT auth to OpenBao, KV-v2 reads from `secret/data/apps/<app>/*`, dynamic-credential reads, in-memory cache with TTL refresh, never writes secrets to disk/log/error
- **OpenBao paths follow Vault Secrets Operator conventions** so future non-Go consumers can layer VSO on top without rework (rationale captured in ADR-0013)
- **OpenBao templated policy** at `infrastructure/openbao/policies/app-template.hcl` so each app reads only its own `secret/data/apps/<its-name>/*` and database roles prefixed `<its-name>-`
- **Architecture doc** `docs/01-architecture/06-api-pattern.md` (Tier 4 + outbound credential policy section)
- **ADR-0013** (no `.env` — outbound secrets via OpenBao; includes Hardened-mode rollout plan and VSO-compatible-paths rationale)
- **Four runbooks**: secrets-library, migrate-env-to-openbao (mandatory git-history audit + rotation), new-app-bootstrap, secrets-guardrails-verification, secrets-guardrails-monitoring
- **CLAUDE.md updated** with the no-`.env` bright-line rule
- **Prevention guardrails** (multi-layer, defense-in-depth):
  - `templates/app-repo/`: `.gitignore`, `.env.example`, `.pre-commit-config.yaml` (gitleaks + block-env-files + block-secret-shaped-vars), `.dockerignore`, `Dockerfile.example`, CI workflow snippet, **`.template-version` file** so the rolling-template-update job in Phase 7 can detect drift
  - CI guardrails mirror pre-commit so `--no-verify` cannot bypass
  - Trivy reconfigured to fail (not warn) on secret findings
  - **Kyverno ClusterPolicy `no-secret-shaped-env-vars`** (Enforce mode) blocks Pods with `*KEY*`/`*SECRET*`/`*TOKEN*`/`*PASSWORD*`/`*CREDENTIAL*` env names in `app` namespace
  - **Self-expiring escape hatch**: `secforge.local/legacy-secret-env: <ticket-id>` annotation must be paired with `secforge.local/legacy-secret-env-expires: <YYYY-MM-DD>` (max 90 days out); a second Kyverno policy refuses admission for missing/expired/too-far expiry, and emits `severity=high` events 14 days before expiry
  - `apps/lib/secrets/` runtime hygiene: `Secret` type redacts via `String()`/`MarshalJSON()`, `Use()`-pattern access with best-effort zero, **`Hardened` mode default for new apps** with explicit migration plan in ADR-0013, redaction-aware internal logger
  - **Error-reporter scrubber wired into a no-op sink in 6b-2** (not just committed) so Phase 7's Sentry/Rollbar wire-up is just a sink swap — closes the "scrubber exists but isn't running" gap
  - **`apps/security-events-collector/`** authenticates inbound CI/Kyverno webhook calls via SPIFFE-SVID (or short-lived JWT for off-cluster CI), tags every event with the verified `actor` field — payload-claimed actor is overridden so fake events from compromised callers cannot launder identity
  - Eight-case verification packaged as **executable test scripts** under `infrastructure/secrets-guardrails/verify/run-all.sh` (not a manual checklist) so guardrails stay verified for the life of the platform; weekly cron in Phase 7
  - **Structured `secrets.guardrail.bypass` events** emitted by every layer with consistent JSON schema, correlation IDs, and a fuzz-tested guarantee that no secret value ever appears in an event payload. Phase 7 ingests via Promtail and adds Grafana dashboard + Alertmanager rules.
- **Phase 10 prompt updated** to mandate the library + per-app `.template-version` adoption

**Known follow-ups:**
1. **Tier 5 — inbound M2M / third-party access to our APIs.** OAuth 2.1 `client_credentials` with `private_key_jwt`, separate Keycloak client per integration. Scheduled for the first time we actually need it.
2. **Hardened-mode default flip.** When all in-cluster apps are Hardened-mode, change library default and remove the non-Hardened code path. Scheduled for pre-AWS-migration.

**Verification:**
- Library unit tests pass
- Throwaway test API exercises 4 secrets cases: secret read happy path, cross-app read denied, value never leaks into logs/errors, scrubber middleware fires on near-leak
- All 8 guardrail-verification scripts pass; each emits exactly one corresponding `secrets.guardrail.bypass` event
- Fuzz test confirms no secret pattern ever appears in any emitted event regardless of input
- Self-expiring annotation verified: missing-expiry denied, past-expiry denied, far-future-expiry denied, valid annotation admitted with event emission
- `apps/security-events-collector/` rejects unsigned/unauthenticated webhook calls

**See:** [docs/05-claude-code-prompts/phase-06b-2-outbound-secrets.md](./docs/05-claude-code-prompts/phase-06b-2-outbound-secrets.md) — split out from `phase-06b-api-pattern.md` on 2026-05-01 when 6b-1's prompt was retargeted to 6b-1-only. The 6b-2 content is unchanged and was never stale (it's about outbound secrets + guardrails, independent of token-exchange).

---

## Phase 7 — Observability *(4 days)*
**Status: ✅ Complete (Sessions 1–4, 2026-04-29 → 2026-05-01). All sub-phases shipped: 7.0/7.1/7.2/7.3/7.4/7.5/7.6/7.7/7.8/7.9/7.10. The 7-day SPIFFE-CSI startupProbe soak runs as a background-monitoring task; not phase-blocking. Three follow-ups carried into Phase 7d: Wazuh agent hardening, Keycloak/OpenBao→Wazuh syslog forwarding, Wazuh OIDC federation. See [docs/03-runbooks/wazuh-operations.md § Deferred components](./docs/03-runbooks/wazuh-operations.md#deferred-components) for context.**

> **Fix-after-07 package applied 2026-05-01.** Findings catalog: [`Fix after 07/00-audit-findings.md`](./Fix%20after%2007/00-audit-findings.md). Six commits (`bbe223b` § A interface refactors → `c92edf0` § B cluster fixes → `529daa7` § C ADRs+arch → `b5506a1` § D PLAN.md+nav → `ca00464` § F threat model → § E merge); diff: `git log fix-after-07-complete`. Highlights: F-APP-1..6 closed (vendor-neutral OIDC/secrets/AuthZN interfaces in `apps/lib/`), F-CLU-1 closed (4 OpenBao pods carry `wait-for-spiffe-csi` init container), F-CLU-2 absorbed into Phase 7c (per Option C — non-mesh AuthZ policies would silently no-op until STRICT cutover), F-ADR-1..11 closed (5 new ADRs + arch-doc fixes), F-ORD-2..10 closed (PLAN.md status truth + dependency graph + 19 phase prompt navigation headers), F-ADR-13 closed (initial STRIDE threat model at [`docs/04-security/threat-model.md`](./docs/04-security/threat-model.md) — 8 Accepted residuals signed off). Open follow-ups: F-ADR-12 (Cosign Audit→Enforce flag, supply-chain phase) flagged in threat model X-R2.

> ### 🔜 Next session resume point (last updated 2026-05-01 — Session 3 partial)
>
> **Session 3 partial (2026-05-01):** OTel collector Service foundation + 3 ServiceMonitors landed. Resumed after a cold-cluster recovery (Shamir unseal + Transit token rotation, captured in operator backlog #4 + Phase 7d).
>
> **Done in Session 3:**
> - **OTel collector Service** — `08-otel-collector-values.yaml` revision 2: `service.enabled: true` + `internalTrafficPolicy: Local`. `otel-collector.observability.svc:4317` (gRPC) / `:4318` (HTTP) now resolvable cluster-wide.
> - **ServiceMonitors / PodMonitor (Step 2 of 7.6 — COMPLETE)**:
>   - Keycloak `infrastructure/keycloak/08-servicemonitor.yaml`
>   - SpiceDB `infrastructure/spicedb/07-servicemonitor.yaml`
>   - istiod `infrastructure/istio/07-istiod-servicemonitor.yaml`
>   - ztunnel PodMonitor `infrastructure/istio/08-ztunnel-podmonitor.yaml`
>   - **OpenBao** `infrastructure/openbao/09-servicemonitor.yaml` + telemetry stanza in `04-openbao-values.yaml` (revision 8): listener-side `unauthenticated_metrics_access = true` (gated by existing `allow-prometheus-to-openbao-metrics` NetworkPolicy; cloud migration MUST switch to token-auth — inline note + Phase 7d) + top-level `prometheus_retention_time/disable_hostname`. Pods rolled in OnDelete order (2→1→0); seal-bao stayed unsealed; auto-unseal succeeded for all 3. SM scoped via `app.kubernetes.io/instance=openbao` + `openbao-internal=true` to dedupe across the 5 main-OpenBao Services and exclude seal-OpenBao.
>   - **BFF** `apps/helloworld-bff/deploy/07-servicemonitor.yaml` — added `prometheus/client_golang` dep + `mux.Handle("GET /metrics", promhttp.Handler())` in `apps/helloworld-bff/main.go`; `go mod tidy` via dockerized 1.25-alpine; image rebuilt + imported into containerd via `docker save | ctr -n=k8s.io image import` (Docker Desktop's docker-daemon vs containerd image stores need an explicit import for `imagePullPolicy: Never` rolls). Added Prometheus → BFF rule to `05-networkpolicies.yaml`.
>   - **AuthZEN façade** `apps/authzen-facade/deploy/06-servicemonitor.yaml` — same code-change pattern (Go 1.23 picked `client_golang` v1.12.1). Added Prometheus → AuthZEN rule to `04-networkpolicies.yaml`. Plus a new mesh AuthorizationPolicy `allow-prometheus-to-authzen-metrics` in `infrastructure/istio/06-authz-default-deny.yaml` because observability ns is not in the mesh — no `from` clause (any source allowed on :8080), with NP as the L4 boundary; can be tightened to a path filter once a Waypoint exists for AuthZEN (Phase 7c candidate). One stale-state authzen pod required a manual delete to refresh ztunnel's view.
>   - All targets confirmed `up=1`: 29 total (1 Keycloak + 1 SpiceDB + 1 istiod + 1 ztunnel + 3 OpenBao + 1 BFF + 2 AuthZEN + chart-installed defaults).
>
> **Sessions 1+2 closed.** Observability stack live and persisted; carry-ins resolved or closed-with-evidence. What remains is the telemetry + dashboard + alerting tail of Phase 7, plus Wazuh.
>
> **Done across Sessions 1+2 (helm STATUS: deployed, all pods Ready):**
> - 7.0.a startupProbes — **apps done** (helloworld-bff, authzen-facade). **OpenBao roll deferred** to operator backlog (needs Shamir keys; see "Operator backlog" below).
> - 7.0.b `realm_access.roles` — **closed deferred-with-evidence**. Keycloak Evaluate tool conclusively proves Keycloak side is correct. Defect is OpenBao 2.5.3 (upstream). Live config uses `preferred_username` fallback. **Open follow-up:** file issue against `https://github.com/openbao/openbao` when motivated.
> - 7.0.c OIDC CLI redirect URI — working
> - 7.1 architecture doc — `docs/01-architecture/08-observability.md`
> - 7.3 kube-prometheus-stack revision 6 — Grafana OIDC + workaround, platform-health dashboard, NetworkPolicies
> - 7.4 Loki revision 4 — single-binary, MinIO-backed, retention disabled, label-gated. Promtail revision 3 (DaemonSet, 111 active files, 204 to Loki).
> - 7.5 Tempo revision 3 — single-binary, MinIO-backed, expand-env enabled. OTel-collector revision 1 (DaemonSet).
> - Platform-health dashboard — `infrastructure/grafana/dashboards/platform-health.json`
> - Path A Keycloak client pattern — `infrastructure/keycloak/clients/grafana.sh`
> - Runbooks added — `keycloak-client-provisioning.md`; OIDC userinfo debug section appended to `keycloak-operations.md`
> - PLAN.md follow-up #1 — updated with empirical findings
>
> **Operator backlog (do these between sessions, no Claude needed):**
> 1. **OpenBao 7.0.a roll** — your Shamir keys required. Order: seal-bao first → unseal → main bao auto-unseals via Transit. Result: all 4 OpenBao SPIFFE-CSI consumers (`openbao-0/1/2` + `openbao-seal-0`) carry the wait-for-socket init container gate. (Apps `helloworld-bff` + `authzen-facade` already self-heal via HTTP startupProbes — verified Fix-after-07 §B.1, F-CLU-1.)
> 2. **`notes/loki-baseline-*`** — keep as historical "what broken Loki looked like" or prune. Either is defensible.
> 3. **OpenBao upstream issue** (optional, when motivated) — file against `https://github.com/openbao/openbao` for the `realm_access/roles` userinfo bug.
> 4. ~~**Transit unseal token expired after multi-day pause**~~ ✅ **Resolved 2026-05-02 (Phase 7d Item 3).** Switched from `-ttl=24h -renewable=true` to `-period=720h` (30-day periodic token). Periodic tokens auto-refresh their TTL on every USE — including the main OpenBao's `transit/decrypt/unseal` call at boot. Any cluster reboot within 30 days transparently extends the token's life. Cold-pause must exceed 30d before recovery script needed (vs prior 24h). Updated `init-seal.sh` + `rotate-transit-token.sh` + ADR-0009 § Known local gaps #4 + `openbao-seal-unseal.md` + `openbao-recovery.md`. Live token still has 24h TTL until next `rotate-transit-token.sh` run.
> 5. **Threat model (`docs/04-security/threat-model.md`)** — missing since Phase 1; folded into `Fix after 07/01-fix-prompt.md` Section F. Will be created when the Fix-after-07 package runs (post-Phase-7 ✅). README contradiction (Phase 1 vs after-Phase-6 wording) was fixed 2026-05-01.
> 6. ~~**🚨 Git initialization (HIGH PRIORITY)**~~ — ✅ **CLOSED 2026-05-01.** Initial commit `10c6a06`, signed with ed25519. SSH signing verified (`Good "git" signature for jaupole@gmail.com`). Pre-commit hooks active (gitleaks + standard hygiene). Gitleaks pre-flight scan returned **zero findings** — CLAUDE.md "no secrets in code, ever" rule held across all 7 phases. Full decision record: [ADR-0021](./docs/02-decisions/0021-git-initialization-and-commit-signing.md). Remote deferred to Phase 9 / cloud-migration time. Unblocks: Fix-after-07 package, Phase 6b-1 implementation, Phase 9, commit signing for the supply-chain phase.
> 7. ~~**🚨 OpenBao `auth/oidc/role/admin` degraded — admin auth locked out (HIGH, surfaced 2026-05-01 post-Fix-after-07)**~~ — ✅ **CLOSED 2026-05-01.** Root cause was NOT the role config (which was always healthy on every monitored field) but a missing NetworkPolicy egress rule for `openbao → ingress-nginx:443`, which prevented OpenBao from fetching Keycloak's OIDC discovery URL via the public hostname (the URL Keycloak puts in `iss` claims). Original error messages "Unable to authorize role" + "Invalid role" were misleading framing of a network-layer timeout. **Fix:** added a single egress rule into `infrastructure/openbao/06-networkpolicies-main.yaml` `allow-openbao-egress` for `namespaceSelector: ingress-nginx, port: 443`. Verified V1 (in-pod wget to discovery URL), V2 (`auth/oidc/config` status `invalid → valid`, warnings cleared), V3 (host-side `bao login -method=oidc role=admin` succeeds end-to-end). Full diagnosis + Resolution in [`Fix after 07/00-audit-findings.md` § F-CLU-11 Resolution (2026-05-01)](./Fix%20after%2007/00-audit-findings.md#resolution-2026-05-01--resolved). **Unblocks:** Grafana `client_secret` rotation; any future OIDC-bound admin operation; Phase 9 prerequisites are now operationally clean (no remaining caveats).
> 8. **`docs/03-runbooks/openbao-recovery.md` § "Generate a new root token via recovery keys" is stale on OpenBao 2.5.3** (surfaced during F-CLU-11 investigation). `bao operator generate-root -init` returns `405 unsupported operation` against `sys/generate-root/attempt`; likely OpenBao 2.5.x restricts that endpoint on Transit-auto-unsealed instances. The `Kubernetes auth break-glass` path in the same runbook (lines 24-44) DID work cleanly and was used to obtain the admin token for the F-CLU-11 fix. Needs: source-grep against OpenBao 2.5.3 to confirm whether the API moved or was removed; either fix the runbook to use the working endpoint OR document `Kubernetes auth break-glass` as the preferred path with recovery-key flow as a "if break-glass also unavailable" fallback. Effort: ~30 min once someone has time to read OpenBao source.
> 9. **Docker Desktop resource allocation undersized for current platform footprint** (surfaced 2026-05-01 during Grafana 13.0.1 rotation, Session 4) — the underlying issue isn't just "observability memory tight"; it's that the Docker Desktop resource ceiling has been outgrown. Need either a Settings → Resources bump (CPUs 6→8+, possibly memory too) **OR** a systematic right-sizing pass across high-request workloads. Symptoms in one session: observability memory quota at 94% post-bump (raised 10Gi→14Gi mid-session — see `infrastructure/namespaces/namespaces.yaml` quota comment), node CPU at 97.5% request utilization (5850m/6000m), Grafana rolling-update blocked **twice in one session** (first by memory quota at 9664Mi/10Gi, then by CPU after the memory bump unblocked it). Phase 7 follow-up territory — fold into a new 7.0.c or queue for Phase 7d. Effort: ~5 min for the Docker Desktop bump; 1–2 hours if we go the right-sizing route.
> 10. **Script Grafana `client_secret` rotation via kcadm-admin** (deferred from Session 4 rotation) — replaces the current `kcadm-grafana-tmp` Path A throwaway client pattern with a reusable script that follows the Phase 3 follow-up pattern (auth via `infrastructure/keycloak/scripts/kcadm-admin.sh` with secret fetched from OpenBao at `secret/data/keycloak/kcadm-admin/client-secret` per ADR-0022). Run order when scripted: revoke `kcadm-grafana-tmp` → write `infrastructure/keycloak/scripts/rotate-grafana-client-secret.sh` → mint new Grafana client secret → store at `secret/data/keycloak/grafana/client-secret` in OpenBao → patch Grafana deployment env (or restart so VSO refreshes if Grafana ever moves to that path) → smoke-test OIDC login. Effort: ~1 hour. **Cadence reminder ("next due ~2026-08-01") lives in a separate `/scheduled` agent — not tracked here**, since multi-month due-dates rot in a backlog list.
> 11. **ADR-0022 § Bootstrap caveat is incomplete** (surfaced 2026-05-02 during Phase 6b-2 operator-time prerequisites). The caveat currently documents kcadm-admin bootstrap as a one-step manual UI client creation, but the actual procedure on a fresh cluster is **5 UI steps + 11 role grants across 3 realm-management clients** (master-realm, platform-realm, secforge-tenants-realm) before the script can self-bootstrap. The operator just walked the full procedure end-to-end and it's documented in [`docs/06-reference/operator-cheatsheet.md` § 6](./docs/06-reference/operator-cheatsheet.md#6-bootstrap-kcadm-admin-from-scratch-the-actual-5-step-procedure); ADR text + `infrastructure/keycloak/clients/kcadm-admin.sh` script header still understate the work. Update both to match. Effort: ~30 min.
> 12. **api-auth: service-tier-without-DPoP path for collector ingestion** (surfaced 2026-05-02 during Phase 6b-2 LIVE verify-08 phase-2). [ADR-0014](./docs/02-decisions/0014-api-auth-library.md) currently mandates DPoP unconditionally on every inbound request — the correct posture for **user-tier** browser-bound tokens where DPoP is the XSS-exfiltration replay defense. The collector's actual callers are **service-tier**: in-cluster callers use SPIFFE-SVID via mTLS (already cryptographically bound — DPoP redundant), out-of-cluster CI runners use Keycloak `client_credentials` JWTs with `typ: at+jwt` (RFC 9068; DPoP would help but adds tooling cost on every CI runner, and is not where most CI tooling lives natively). **Symptom:** `LIVE=1 bash infrastructure/secrets-guardrails/verify/run-all.sh` reports verify-08 phase-2 FAIL — the `legacy-env-warner` CronJob (and any future CI runner) cannot authenticate to `security-events-collector`; every inbound gets `ErrDPoPMissing` → synthesized `{actor:"unauthenticated", outcome:"blocked"}` rejection event, never the `outcome:"annotated-bypass"` the verify probe wants. Verified empirically via host-side `curl` with a security-events-ci client_credentials token: collector returns 401 with `rule="collector.auth: apiauth: invalid token"`. **Until this lands**, verify-08 LIVE phase-2 is operator-validatable manually only (the LIVE summary settles at 7/8 PASS by design, not regression). **Proper fix:** ADR-0014 amendment + `Middleware.ServiceTierMode` (or audience-based branching that skips the DPoP check when `typ: at+jwt`) + tests + collector redeploy. Effort: ~1-2 days of focused Phase 6b-1 follow-up work.
> 13. ~~**Migrate `BFF_VALKEY_PASSWORD` to OpenBao via `apps/lib/secrets/`**~~ ✅ **Closed 2026-05-05 (S4 audit cleanup).** Template fixed in `apps/helloworld-bff/`: `cfg.ValkeyPassword` removed; the session store now holds an `apps/lib/secrets/` Client + Valkey client behind a RWMutex and refreshes on AUTH failure (mirrors `helloworld-backend/db.go`'s 28P01 path; see `apps/helloworld-bff/session.go` `doWithRetry` + `isAuthFailure`). Deployment manifest dropped the `BFF_VALKEY_PASSWORD` env + the `secforge.local/legacy-secret-env` annotation pair (Kyverno admits cleanly via `kubectl apply --dry-run=server`). Permanent bootstrap script at `infrastructure/helloworld/provision-bff-bao.sh` (idempotent, re-runnable on Valkey password rotation). Phase 10 BFFs (`project-tracker-bff`, `proposal-forge-bff`, `pm-bff`) cloned from this template inherit the correct pattern from day one.
> 14. **Docker Desktop containerd image-load quirk** (surfaced 2026-05-02 during Phase 7b.5 runtime verification). `docker save local/<image>:<tag> | docker exec -i desktop-control-plane ctr -n=k8s.io images import -` reports `total: 0.0 B (0.0 B/s)` on every reload of an image whose tag is already cached in containerd, even after `crictl rmi <image>:<tag>` AND scaling the consuming Deployment to 0 replicas. The pre-existing image ID stays bound to the tag indefinitely; the new build (verifiable in `docker images` with a fresh content sha256) never reaches the kubelet's containerd. Same shape on `docker cp` into the Docker Desktop VM (file appears in `docker cp` output but `docker exec ... ls` reports `no such file or directory`). Confirmed reproducer on helloworld-bff. **Symptom for Phase 7b:** the post-7b.5 helloworld-bff binary (with the OTel-span-event sink) cannot be deployed for live verification of "scrubbed errors appear as span events in Tempo" — the running pod keeps using the pre-Phase-6b-2-commit-5 image (`b0158279476bd...`) which doesn't even have the errreport wiring yet. **Workaround paths to investigate:** (a) `kind load docker-image` if Docker Desktop K8s actually uses kind under the hood, (b) push to a local registry (we have `registry/` running), reference by registry URL in deploy manifests, (c) build directly into containerd via `nerdctl build` from inside the Docker Desktop VM. Effort: ~1-2 hours of investigation; resolution unblocks every future image-redeploy iteration on this cluster, not just 7b.5's verification.
> 15. ~~**Istio Ambient AuthZ-denial observability gap**~~ ✅ **Resolved 2026-05-03 — original finding was at the wrong log level.** The 2026-05-02 test ran at `RUST_LOG=info` and `=debug`; neither surfaces denial decisions. **At TRACE level, the full RBAC trace is visible.** Specifically: at `RUST_LOG=trace` (or `ztunnel::rbac=trace,ztunnel::state=trace,info` for the focused subset), ztunnel emits per-policy decisions under scopes `ztunnel::state` (`"checking connection"`, `"allow policy match"`, `"allow policy does not match"`, `"deny policy match"`, `"deny policy does not match"`) and `ztunnel::rbac` (per-clause matcher trace including which `from`/`to`/`namespace`/`port` field rejected). Verified end-to-end on 2026-05-03: temporary explicit DENY policy + probe pod in `default` ns → `authzen-facade` pod IP at :8080 — every clause evaluation logged. **Note:** at DEBUG level, only positive ALLOW matches log (`"allow policy match"` under `ztunnel::state`); denials require TRACE. **No dedicated Prometheus denial counter** exists on ztunnel 1.29.2 — only `istio_tcp_connections_opened_total` with `response_flags` (always `-` in our observed traffic) and `connection_security_policy` (always `unknown`). **Operator pattern for Phase 7c cutover:** bump ztunnel to trace via the admin port (`POST :15000/logging?level=trace` from inside the pod, no restart) for the cutover window, drive cutover, drop back to info. Capture the LogQL query for promtail-collected ztunnel JSON logs (`{namespace="istio-system",pod=~"ztunnel-.*"} | json | scope="ztunnel::state" | message=~"deny policy.*"`) into `docs/03-runbooks/istio-strict-cutover.md` when 7c proper starts. **Phase 7c unblocked; STRICT cutover ready when the operator allocates the 1-2 day window.**
> 16. ~~**Phase 5.7 regression — `secforge-app` DB engine root-cred drift**~~ ✅ **Resolved 2026-05-02.** Re-bootstrapped `database/config/secforge-app` with the current CNPG-issued password from `secforge-app-db-app` Secret. CREATEROLE was already intact on the `app` user (verified via `pg_roles`). `bao read database/creds/helloworld-app-readwrite` now mints cleanly (lease_duration=3600, fresh `v-kubernet-hellowor-…` username). Did NOT run `database/rotate-root/secforge-app` since helloworld-app isn't deployed yet; future operator can rotate-root after Phase 9 deployment if they want OpenBao to claim password ownership.
> 17. **Phase 7d.5 — Wazuh agent `client.keys` persistence** (surfaced 2026-05-02 during Phase 7d Item 5 verification). Agent's `/var/ossec/etc/` is mounted as EmptyDir; `client.keys` doesn't persist across pod restarts. Agent auto-enrolls cleanly the first time, but on pod restart the empty `client.keys` triggers re-enrollment, manager rejects with `Duplicate agent name` (gated by `<after_registration_time>`). Effect: agent shows `Active` on manager but `wazuh-logcollector` doesn't reach steady state, blocking Item 6's pod-log event flow. **Fix:** pre-register the agent on the manager once, extract the key, store as a K8s Secret in `wazuh-agent` ns, mount as `/var/ossec/etc/client.keys` via subPath. Drop the `WAZUH_REGISTRATION_*` env vars from the DaemonSet so agentd doesn't auto-enroll. Effort: ~30–60 min. Recovery procedure for the running cluster documented in `docs/03-runbooks/wazuh-operations.md § 1`.
> 18. **Phase 7d.6 — Manager-side custom decoders for OpenBao audit JSON + Keycloak event JSON** (surfaced 2026-05-02 during Phase 7d Item 6). Agent-side `<localfile>` config (in `infrastructure/wazuh-agent/03-configmap.yaml`'s ossec-supplements.xml) tails the pod logs cleanly when the agent is stable. Manager-side custom decoders at `/var/ossec/etc/decoders/local_decoder.xml` to extract specific fields from OpenBao's audit JSON shape + Keycloak's event JSON shape are NOT in this commit. Without them, events ship as `wazuh-alerts` entries with `data.*` raw fields but no parsed Wazuh field mappings. **Fix:** write `local_decoder.xml` with `<decoder name="openbao-audit">` and `<decoder name="keycloak-event">` blocks matching each format; mount via ConfigMap into the manager pod at the decoders path; reload manager. Effort: ~1 hour once decoder rules are written + tested.
>
> **Next session menu (suggested order — 7.6 + 7.7 highest leverage; dashboards have no real data until telemetry is wired):**
> 1. **7.6 telemetry wiring (continue)** —
>    - ✅ OTel collector Service (Session 3)
>    - ✅ ServiceMonitors: Keycloak, SpiceDB, istiod (Session 3)
>    - ✅ OpenBao SM + telemetry stanza (Session 3, unauth+NetPol; cloud migration TODO in Phase 7d)
>    - ✅ ztunnel PodMonitor (Session 3)
>    - ✅ BFF `/metrics` + SM (Session 3)
>    - ✅ AuthZEN `/metrics` + SM + mesh-AuthZ allow rule (Session 3)
>    - ✅ **Tracing wiring (Step 3 of 7.6) — DONE for the 4 main components** (Session 3):
>      - Istio: corrected `extensionProviders.opentelemetry.service` from `opentelemetry-collector` to `otel-collector` in `02-istiod-values.yaml` (the original value didn't match `fullnameOverride: otel-collector`); helm-upgraded istiod. `defaultProviders.tracing: opentelemetry` was already set, so no Telemetry CR needed.
>      - SpiceDB: added `otelProvider/otelEndpoint/otelInsecure/otelSampleRatio` to the `SpiceDBCluster` config; operator rolled the deployment.
>      - Keycloak: added 5 Quarkus tracing additionalOptions (`tracing-enabled`, `tracing-endpoint`, `tracing-protocol=grpc`, `tracing-sampler-type=always_on`, `tracing-service-name=keycloak`); operator rolled. Added `allow-keycloak-egress` rule to `infrastructure/keycloak/07-networkpolicies.yaml` for OTLP to observability ns:4317 (was timing out without it).
>      - BFF + AuthZEN: added `tracing.go` (OTLP gRPC exporter + propagators), wrapped HTTP handlers with `otelhttp.NewHandler` (filtering /metrics + /healthz + /ready). New deployment env: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector...:4317` (the `http://` prefix is **required** — Go SDK's gRPC exporter rejected the bare `host:port` form with `delegating_resolver: invalid target address "": missing address`). AuthZEN's `go.mod` + Dockerfile bumped to Go 1.25 because `otelhttp v0.68.0` needs it. Egress NPs extended for both. Added `allow-otlp-ingress-to-otel-collector` NetworkPolicy in observability ns (default-deny-ingress was blocking cross-ns OTLP fan-in).
>      - **OpenBao tracing skipped:** OpenBao 2.5 has no native OTLP exporter — only Prometheus/datadog sinks in the `telemetry` stanza. It's a leaf component (called only at BFF bootstrap), so missing it from request-flow traces is acceptable. Tracked as a Phase 7d candidate (revisit on upstream support).
>      - Verified end-to-end: 4 services confirmed in Tempo `service.name` tag values: `authzen-facade`, `helloworld-bff`, `keycloak`, `spicedb`.
> 2. ✅ **7.7 dashboards** (Session 3) — added 4 starter dashboards as ConfigMaps with `grafana_dashboard=1` label; Grafana sidecar provisions them on file-watch (the reload-API call to `https://grafana.secforge.local/api/admin/provisioning/dashboards/reload` fails from inside the cluster, which is noisy but harmless — files land in `/tmp/dashboards/` and Grafana picks them up on its scan cycle):
>    - `infrastructure/grafana/dashboards/auth-events.json` — Keycloak HTTP rate by outcome, p99 latency by URI, JVM heap, Agroal pool, Loki tail of LOGIN/LOGIN_ERROR/LOGOUT/REFRESH_TOKEN events
>    - `infrastructure/grafana/dashboards/authz-checks.json` — SpiceDB CheckPermission rate, p50/p95/p99 latency, gRPC error rate, cache hit ratio, AuthZEN evaluate-log tail
>    - `infrastructure/grafana/dashboards/secret-access.json` — OpenBao audit req/sec, login req/sec, locked users, audit failures, p99 audit latency, audit-log tail
>    - `infrastructure/grafana/dashboards/service-mesh.json` — ztunnel TCP open/close/fail, throughput, open sockets, istiod xDS bytes, DNS upstream p99
>    - Apply script: `infrastructure/observability/apply-dashboards.sh` (parameterized over all `*.json` files; replaces the old single-purpose script). Each dashboard is a ConfigMap named `grafana-dashboard-<basename>`.
> 3. ✅ **7.8 Alertmanager** (Session 3) — `infrastructure/observability/13-alerting-rules.yaml` adds a `secforge-platform` PrometheusRule with 10 alerts in 5 groups (`secforge.platform`, `secforge.auth`, `secforge.authz`, `secforge.secrets`, `secforge.mesh`): PodCrashLooping, OpenBaoSealed, NamespaceMemoryHigh, KeycloakHTTP5xxRate, KeycloakDBPoolExhausted, SpiceDBCheckLatencyHigh, SpiceDBGRPCErrorRate, OpenBaoLockedUsers, OpenBaoAuditFailures, IstioTCPConnectionFailureSpike. All loaded `health=ok state=inactive`. Receiver remains `null` (local edition — alerts visible in Alertmanager UI / Grafana Alerting / Prometheus `/alerts`). Companion runbook `docs/03-runbooks/alerts.md` documents diagnose+remediate per alert and links to `openbao-seal-unseal.md` / `openbao-recovery.md` for the operationally-trickiest paths.
> 4. ✅ **7.9 end-to-end verify** (Session 3) — `infrastructure/observability/verify-e2e.sh` is a self-contained idempotent script that fires synthetic traffic (5× BFF /login + 3× AuthZEN /access/v1/evaluation) and checks that each of the four observability pillars sees the activity. Last run: **8/8 green** — BFF/AuthZEN/Keycloak/OpenBao logs in Loki, BFF/AuthZEN/Keycloak/SpiceDB traces in Tempo, Prometheus counter increments confirmed. Passkey-driven full-flow verification (browser → Keycloak login form → BFF callback) is more elaborate and tracked as a Phase 9 task — for Phase 7 closure, the synthetic-traffic verify is sufficient because every pillar is shown to receive data end-to-end. Two findings from running it: Loki was rejecting old log entries (`entry too far behind`) immediately after a fresh deploy — these are stale once Promtail catches up; verify script uses a 1h log window to avoid the window-too-narrow false negative. BFF emits no per-request logs today (only startup) — adding request-scope structured logging is a Phase 9 / Phase 10 hygiene task.
> 5. ✅ **7.10 documentation finalization** (Session 3) — `docs/01-architecture/08-observability.md` updated to reflect deployed reality (status table; OpenBao unauth-metrics + cloud TODO; ztunnel PodMonitor; OpenBao tracing deferred; Go SDK `OTEL_EXPORTER_OTLP_ENDPOINT` `http://`-scheme caveat). `docs/03-runbooks/grafana-dashboards.md` created (catalog of 5 dashboards, add/update procedure, conventions, common pitfalls, alert→panel mapping). `docs/03-runbooks/alerts.md` was created in 7.8. `docs/03-runbooks/wazuh-operations.md` update is gated on 7.2 Wazuh being deployed.
> 6. 🟨 **7.2 Wazuh** — **executing now (Session 4, 2026-05-01)**. See [Phase 7.2 — Wazuh deployment](#phase-72--wazuh-deployment-1-day-dedicated-session) below for the 4-step runbook with decision gate at step 3.
>
> When Phase 7 fully closes (all of the above + soak verification), run `Fix after 07/01-fix-prompt.md` (see `Fix after 07/README.md` for prerequisites). Do NOT run it before Phase 7 ✅.

Wazuh, Prometheus, Grafana, Loki, OpenTelemetry → Tempo. All running locally. Plus three small carry-ins from Phase 5/6 follow-ups (Phase 7.0 in the prompt doc).

**Deliverables:**
- **Phase 7.0 carry-ins (do BEFORE the observability stack design):**
  - SPIFFE-CSI startupProbe fix on 6 workloads (openbao-0/1/2, openbao-seal-0, helloworld-bff, authzen-facade); per-workload probe tuning (don't hardcode socket paths — names vary by SPIFFE-CSI driver version); soak target = zero post-boot manual `kubectl delete pod` ops for 7 consecutive days
  - `realm_access.roles` claim plumbing debug (success path: rebind OpenBao admin role; fallback: document Keycloak userinfo behavior; sequencing: must run AFTER 7.4 Loki goes live; 90-day fallback escalation trigger 2026-07-29)
  - OIDC CLI redirect URI fix (~30 min): add `http://localhost:8250/oidc/callback` to both `infrastructure/openbao/configure-auth-oidc.sh` and `infrastructure/keycloak/clients/openbao.sh`
- Wazuh manager + indexer + dashboard (slimmed for local)
- Wazuh agent DaemonSet
- kube-prometheus-stack
- Loki + Promtail (or Vector) for app logs
- OpenTelemetry Collector → Tempo
- Initial dashboards: auth events, authz checks, error rates, platform health (the platform-health dashboard's pod-restart panel is the verification surface for the 7.0.a soak)
- Alertmanager configured (alerts go to your local email or just to logs in dev)

**Note:** Secret-guardrail monitoring wire-up moved to Phase 7b (separated because Phase 6b-2 may not be complete by the time Phase 7 runs). Istio SPIRE-as-CA cutover + STRICT moved to Phase 7c. BFF private_key_jwt rotation + SpiceDB datastore_uri → database-engine moved to Phase 7d.

**See:** [docs/05-claude-code-prompts/phase-07-observability.md](./docs/05-claude-code-prompts/phase-07-observability.md)

---

## Phase 7.2 — Wazuh deployment *(1 day, dedicated session)*
**Status: ✅ Complete (2026-05-01, Session 4) — chart vendored at `infrastructure/wazuh/vendor/wazuh/` (`ileonelperea/wazuh-helm` 1.2.10, App 4.14.4, MIT, single-maintainer; 2 patches applied — see vendor/PATCHES.md). Indexer + manager + dashboard 1/1 Ready, indexer cluster green, dashboard live at https://wazuh.secforge.local/. Memory cost: 2.72 GiB requested / 4.40 GiB limit. Three deferred items carried into Phase 7d: agent DaemonSet hardening, Keycloak/OpenBao syslog forwarding, OIDC federation.**

Wazuh manager + indexer + dashboard + agent DaemonSet. The 5th pillar of observability (SIEM). Promoted to a dedicated session because of memory budget pressure and an upstream deployment-path decision that must be made before any Helm/Kustomize apply lands.

**Prerequisites:** Phase 7 mainline ✅ (7.0/7.1/7.3/7.4/7.5/7.6/7.7/7.8/7.9/7.10). Phase 7's 7-day soak verification runs in parallel — does not block 7.2.

> ### 🚀 Execution runbook (for wsl Claude — execute in this exact order)
>
> **You are wsl Claude. Read this entire section before starting. The session is structured as 4 steps with a hard decision gate at step 3. Do NOT skip the decision gate — committing 6 hours of deploy work blind is the failure mode this gate prevents.**
>
> #### Step 1 — OpenBao 7.0.a roll *(operator-only; ~15–30 min)*
> The operator runs this with their Shamir keys before you start. Do **not** start step 2 until they confirm OpenBao is healthy and unsealed.
>
> Operator command sequence (for reference; they execute):
> 1. `helm upgrade openbao infrastructure/openbao/...` (applies wait-for-spiffe-csi init container to OpenBao StatefulSets)
> 2. Unseal `openbao-seal-0` with 3 of 5 Shamir keys via `infrastructure/openbao/unseal-seal.sh` (or whatever the current path is)
> 3. Main `openbao-0/1/2` auto-unseal via Transit
> 4. Confirm `kubectl get pods -n openbao` — all 4 pods Running and Ready
>
> **Wait for operator to confirm. Do not proceed without that confirmation.**
>
> #### Step 2 — Deployment-path vetting *(your job; drop to Sonnet for this; ~30 min)*
>
> **Switch model:** `/model sonnet` — this is research, not synthesis. Sonnet handles it fine.
>
> Vet both paths and report findings with concrete evidence (links, last-commit dates, maintainer identity, dependency footprint):
>
> | Path | What to verify |
> |------|---------------|
> | (a) `github.com/wazuh/wazuh-kubernetes` (Kustomize) | Last-commit date; are master+worker manifests separable; is Traefik IngressRoute hard-coded or a kustomize patch surface; cert PEM generation requirements; what does our adaptation cost actually look like (count the kustomize patches we'd need) |
> | (b) Community Helm | List candidate charts on ArtifactHub; for each: maintainer identity, last update, GitHub repo reachable, Helm index exposed at a real URL, schema validation, declared support matrix. **Reject any chart whose Helm repo URL 404s.** |
>
> **Output:** a 200-word summary at the bottom of this file (under a new heading "### Path decision (2026-05-01)") with the choice + rationale + what was rejected and why. Switch back to Opus (`/model opus`) before step 3.
>
> #### Step 3 — Decision gate *(operator + you; ~5 min)*
>
> Show the operator the path-decision summary AND the result of running:
>
> ```bash
> kubectl top nodes
> kubectl describe node | grep -A 5 "Allocated resources"
> ```
>
> The Phase 7.2 spec was written when ~12Gi were free. Confirm that's still roughly true. Wazuh wants 5–6Gi.
>
> **Operator must say one of:**
> - **GREEN — proceed:** memory headroom is fine; chosen path is sane. Continue to step 4.
> - **AMBER — proceed with mitigations:** memory is tight but acceptable with reduced indexer heap (1.5Gi instead of 2-3Gi) or single-replica everything. Document mitigations, continue.
> - **RED — stop:** path turned out harder than expected, or memory is too tight, or something else surfaced. Update this section's status to "⏸️ Blocked — see notes" and explain why. Reschedule.
>
> **Do not proceed past this gate without an explicit operator GO.**
>
> #### Step 4 — Wazuh deploy *(your job; ~4–6 hours; switch back to Opus for design decisions, Sonnet for routine apply work)*
>
> Now execute the deliverables list below. Commit per logical group (one commit per Wazuh component, not one giant commit). Verify each component is Ready before moving to the next.
>
> Order:
> 1. Namespace + NetworkPolicy + Service Accounts + RBAC scaffolding
> 2. Wazuh Indexer (StatefulSet, 1 replica, indexer heap from step 3 mitigation if applicable)
> 3. Wazuh Manager (Deployment or StatefulSet per path choice, 1 replica)
> 4. Wazuh Dashboard (Deployment, 1 replica)
> 5. Wazuh Agent DaemonSet
> 6. Ingress at `wazuh.secforge.local` via ingress-nginx + cert-manager (mirror the Grafana ingress pattern)
> 7. Keycloak `wazuh-dashboard` client via `infrastructure/keycloak/clients/wazuh.sh` (Path A, mirror `grafana.sh`)
> 8. OpenSearch Security plugin OIDC config — `platform_admin` realm role → Wazuh `admin`
> 9. Agent rules verification — confirm CIS K8s benchmark + MITRE ATT&CK rulesets are loaded
> 10. Log forwarding — Promtail external-write target to Wazuh manager TCP/1514 (preferred) OR Filebeat sidecar (fallback). Document the choice.
> 11. Runbook — create `docs/03-runbooks/wazuh-operations.md` (the architecture doc already references it)
> 12. Extend `infrastructure/observability/verify-e2e.sh` with a 5th pillar: `{namespace="wazuh"}` log streams visible AND indexer health probe green
>
> #### Closing tasks
>
> When step 4 ends:
> 1. Run the extended `verify-e2e.sh`. Capture the result. If 5 pillars green, mark this section ✅ Complete.
> 2. Update the quick-reference table at the top of PLAN.md (per the MANDATORY rule in CLAUDE.md § Updating PLAN.md).
> 3. Update the Phase 7 resume-point block — menu item #6 flips from 🟨 to ✅; add a Session 4 summary line.
> 4. Update the operator backlog: remove items resolved by this session.
> 5. Bump the "Last updated" date.
> 6. Ask the operator to confirm before pushing/committing.

### Pre-flight resource check (reference; verified at decision gate)

- Node has **19Gi total / 12Gi available** (as of 2026-05-01); current pod requests sum to **~11.9Gi**.
- Wazuh indexer + manager + dashboard adds **5–6Gi** of requests.
- **Mitigation options if amber/red at decision gate:** lower indexer heap (default 2-3Gi → 1.5Gi), single-replica everything (already the plan), defer deployment until other components have been right-sized, or temporarily raise Docker Desktop memory.

### Deliverables (executed in step 4 above)

- **Wazuh Indexer** — 1 replica, 1.5–3Gi heap
- **Wazuh Manager** — 1 replica
- **Wazuh Dashboard** — 1 replica
- **Wazuh Agent DaemonSet** — runs on every node
- **NetworkPolicy** for `wazuh` namespace
- **Ingress** at `wazuh.secforge.local`
- **OIDC federation** — `wazuh-dashboard` Keycloak client (Path A); OpenSearch Security plugin; `platform_admin` realm role → Wazuh `admin`
- **Agent rules** — CIS K8s + MITRE ATT&CK
- **Log forwarding** — Keycloak + OpenBao JSON STDOUT → Wazuh manager TCP/1514 (Promtail external-write preferred)
- **Runbook** — `docs/03-runbooks/wazuh-operations.md`
- **5th pillar verification** — `verify-e2e.sh` extended

### Out of scope (defer to later phases)

- Wazuh active-response hooks (auto-blocking on alerts) — Phase 10 hardening
- Multi-cluster Wazuh manager federation — cloud edition only
- Wazuh-Tempo trace correlation — cloud edition or Phase 9+ hygiene

**See:** `docs/05-claude-code-prompts/phase-07-observability.md` (the existing Phase 7 prompt covers Wazuh deliverables; this section is the live execution plan).

---

## Phase 7b — Post-6b-2 Monitoring Wire-up *(1-2 days)*
**Status: ✅ Complete 2026-05-02**

Three signed commits landed (`6e9f386`, `cb41a4b`, plus the wrap-up commit
this section is part of). Phase 6b-2's secret-guardrail emission is now
wired through Phase 7's observability stack:

- **7b.1 Promtail scrape** — `extraScrapeConfigs` job `secrets-guardrails`
  in `04-promtail-values.yaml`. Discovers collector pods, JSON-parses
  events, promotes 5 closed-enum fields to indexed labels, emits a
  Prometheus counter (actual name: `promtail_custom_secrets_guardrail_bypass_total` —
  Promtail prefixes user counters with `promtail_custom_`).
- **7b.2 Loki retention** — `retention_stream` of 90d for
  `{job="secrets-guardrails"}`. Aspirational until
  `compactor.retention_enabled` flips (DIAGNOSTIC fresh-bucket boot
  loop documented inline; flip is a separate operator-backlog item).
- **7b.3 Grafana dashboard** — `infrastructure/grafana/dashboards/secrets-guardrails.json`
  (uid: `secrets-guardrails`), 7 panels, tagged `secrets, guardrails, audit`.
- **7b.4 PrometheusRule** — `secforge.secrets-guardrails` group, 4 rules
  (Critical immediate, High in 1m, Annotated-bypass-aged-30d weekly,
  bypass-rate-anomaly 2σ).
- **7b.5 Scrubber sink swap** — helloworld-bff's
  `errreport.ScrubbingReporter` Sink: `NoOpSink` → `otelSink`
  (records scrubbed errors as span events on the active trace span).
  Live runtime verification deferred to operator-backlog #14
  (Docker Desktop containerd-cache image-load quirk). Code change
  compiles + tests pass.
- **7b.6 Weekly verify CronJob** — `infrastructure/secrets-guardrails/cron/01-weekly-guardrail-verify.yaml`,
  Sunday 02:00 UTC.
- **7b.7 Weekly template-drift CronJob** — `02-weekly-template-drift.yaml`,
  Sunday 03:00 UTC. Runs harmlessly until apps stamp the
  `secforge.platform/template-version` annotation (lands with
  Phase 9/10 app provisioning).
- **7b.8 End-to-end verification** — pipeline confirmed live:
  Kyverno admission → collector rejection event (synthesized,
  `outcome=blocked, actor=unauthenticated` per #12) → Promtail
  scrape → Loki ingestion (queryable with `{job="secrets-guardrails"}`)
  → Promtail metric counter increments → Prometheus scrapes
  Promtail's `/metrics` endpoint → all 4 alert rules reference
  the correct metric name.
- **7b.9 Documentation** — runbook (`docs/03-runbooks/secrets-guardrails-monitoring.md`)
  updated with live wire-up details, the Promtail metric naming
  caveat, and the operator-backlog #12 dashboard-panel-emptiness
  consequence. PLAN.md flipped here.

**Operator-backlog rows opened during 7b execution:**
- `#13` — ~~Migrate `BFF_VALKEY_PASSWORD` to OpenBao via `apps/lib/secrets/`~~ **✅ Closed 2026-05-05** (S4 audit cleanup). Template fix landed in `apps/helloworld-bff/session.go` (Client + auth-retry on WRONGPASS/NOAUTH) + manifest cleanup + permanent bootstrap script `infrastructure/helloworld/provision-bff-bao.sh`. Phase 10 BFFs inherit the correct pattern from day one.
- `#14` — Docker Desktop containerd image-load quirk:
  `docker save | docker exec ... ctr import -` reports `total: 0.0 B`
  on every helloworld-bff reload, so the post-7b.5 binary stays
  unloaded even with `crictl rmi` and scaling to 0 replicas. Blocks
  live verification of the OTel scrubber sink.



**Prerequisites:** Phase 7 ✅ AND Phase 6b-2 ✅.

**Deliverables:**
- Promtail scrape config with `job=secrets-guardrails` label for `apps/security-events-collector/` STDOUT
- Loki retention policy: 90 days for `secrets.guardrail.bypass` events (longer than default app-log retention — needed for audit trail)
- Grafana dashboard "Secrets Guardrails": bypass rate by layer/actor/rule, annotated-bypass aging panel, critical-event timeline, expiring-annotation panel (pods within 14 days of `legacy-secret-env-expires`)
- Alertmanager rules:
  - `severity=critical` → page immediately
  - `severity=high` → Slack/email within 1h
  - `outcome=annotated-bypass` aged > 30 days without ticket resolution → weekly digest
  - 7-day rolling baseline anomaly detection on bypass rate
- Error-reporter scrubber: swap the no-op sink wired in 6b-2 for the real OpenTelemetry exporter; the scrubber itself doesn't change
- **Weekly guardrail-verification cron**: runs `infrastructure/secrets-guardrails/verify/run-all.sh` every Sunday; failures emit `severity=critical` events (catches guardrail regressions same week)
- **Weekly template-drift cron**: scans every app repo's `.template-version` against the latest `templates/app-repo/`; opens a PR for outdated apps with the diff. Prevents bootstrapped guardrails from rotting silently as Trivy/Kyverno/Go versions move.

**See:** [docs/05-claude-code-prompts/phase-07b-post-6b2-monitoring.md](./docs/05-claude-code-prompts/phase-07b-post-6b2-monitoring.md)

---

## Phase 7c — Istio SPIRE-as-CA cutover + PeerAuthentication STRICT *(split into 7c-1 ✅ and 7c-2 ⬜ on 2026-05-05)*

### Phase 7c-1 — STRICT in `app` ns under cluster.local *(option-A scope, complete 2026-05-05)*
**Status: ✅ Complete (2026-05-05)** — operator option-A decision. Scope-limited cutover landed in two atomic commits: test-page Phase-1 fixture removed (the only ingress-nginx → non-CNPG path that would have been denied at L4 under STRICT), and a namespace-scoped STRICT `PeerAuthentication` applied to `app` (`infrastructure/istio/05-peer-auth-app-strict.yaml`). The mesh-wide default at `infrastructure/istio/05-peer-auth.yaml` stays PERMISSIVE for every other namespace; trust domain stays `cluster.local`. A workload-scoped PERMISSIVE override on the CNPG cluster (`cnpg.io/cluster=secforge-app-db` selector, `infrastructure/istio/05-peer-auth-app-cnpg-permissive.yaml`) preserves the non-mesh caller paths from openbao (dynamic-cred mint), postgres-operator (CNPG reconciliation + probes), and observability (postgres-exporter scrape) — those three namespaces will be ambient-mesh-enrolled in 7c-2 and the override is removed at that closeout. Verified green: authzen-facade Ready under STRICT; openbao ns → app/secforge-app-db:5432 TCP-connect succeeds through the override; openbao → spicedb dynamic-cred mint passes; ztunnel emitted zero deny-policy lines across the 5-min soak window (LogQL: `{namespace="istio-system",pod=~"ztunnel-.*"} | json | scope="ztunnel::state" | message=~"deny policy.*"`). Note: the CNPG cluster's `Ready=False` condition pre-dated 7c-1 by six days (`lastTransitionTime: 2026-04-29T22:03:54Z`) — postgres-operator → CNPG `:8000` status-extraction was blocked by a NetworkPolicy gap (`allow-openbao-to-secforge-app-db` allows only openbao→5432) since the policy was first applied; observable both with and without 7c-1 STRICT. Closed 2026-05-05 via [operator-backlog #22](./docs/06-reference/operator-backlog.md) — `allow-postgres-operator-to-secforge-app-db` added at `infrastructure/cloudnativepg/clusters/app-db-netpol-operator-status.yaml`.

### Phase 7c-2 — SPIRE-as-CA + multi-ns + trust-domain unification *(deferred)*
**Status: ⬜ Open** — tracked as [operator-backlog #21](./docs/06-reference/operator-backlog.md). Pre-requisite: validate the helm-values diff at `infrastructure/istio/authzpol-strict-7c2-draft/helm-values-spire-ca.draft.diff` against the upstream Istio + SPIRE compatibility docs ([istio.io/latest/docs/ops/integrations/spire](https://istio.io/latest/docs/ops/integrations/spire/)). Scope when it runs: (a) flip Istio to use SPIRE as external CA (disable Citadel), (b) ambient-enroll keycloak + spicedb + openbao + observability + teleport namespaces, (c) rewrite `app`-ns AuthorizationPolicy `principals` from `cluster.local/...` to `secforge.local/...`, (d) flip mesh-wide PeerAuthentication PERMISSIVE → STRICT staged ns-by-ns, (e) remove the 7c-1 CNPG PERMISSIVE workload-scoped override once the upstream callers are mesh-resident, (f) close the [ADR-0010](./docs/02-decisions/0010-istio-ambient-vs-sidecar.md) deferral. Existing prep at `infrastructure/istio/authzpol-strict-7c2-draft/`. Estimated 1-2 day operator window. Soft for Phase 10 — apps go into STRICT in `app` ns on day one under `cluster.local` (already in force from 7c-1); trust-domain unification is independent.

---

## Phase 7c (deprecated header retained for cross-reference) — Istio SPIRE-as-CA cutover + PeerAuthentication STRICT *(history)*
**Status: 🟨 SUPERSEDED 2026-05-05 by the 7c-1 + 7c-2 split above; original prose retained below for context only.**

> **2026-05-03 update — gate closed.** The 2026-05-02 finding ("no log line surfaces" for denials) was at `RUST_LOG=info` and `=debug`. **At TRACE level**, ztunnel emits full per-policy and per-clause RBAC evaluation trace under scopes `ztunnel::state` (decision-summary messages: `"checking connection"`, `"allow policy match"`, `"allow policy does not match"`, `"deny policy match"`, `"deny policy does not match"`) and `ztunnel::rbac` (per-field matcher trace including which `from`/`to`/`namespace`/`port`/`principal` clause matched or rejected). Admin port at `:15000` accepts `POST /logging?level=trace` to toggle without a pod restart. Captured 2026-05-03 with a temporary explicit DENY policy + probe pod in `default` ns → `authzen-facade-7c94c8bbc-6kckl` pod IP at :8080 (probing the pod IP directly bypasses the empty-Service-endpoints-RST trap from kube-proxy when the destination is unhealthy; using a Service VIP doesn't reach ztunnel when no endpoints are Ready). At DEBUG level (production-default), only positive ALLOW matches surface; denials require TRACE. **Operational pattern for the cutover:** bump ztunnel to trace via the admin port for the cutover window (per pod, no helm upgrade), drive the STRICT flip namespace-by-namespace, drop back to info when complete. Capture the LogQL query into the cutover runbook (`docs/03-runbooks/istio-strict-cutover.md` is the file the original 7c.0.1 prompt asked to seed): `{namespace="istio-system",pod=~"ztunnel-.*"} | json | scope="ztunnel::state" | message=~"deny policy.*"`. **No Prometheus denial counter exists on ztunnel 1.29.2** — `istio_tcp_connections_opened_total.response_flags` always shows `-` and `connection_security_policy` always `unknown`; this is a separate upstream gap acknowledged but not gating Phase 7c (logs cover the cutover-window need, metric coverage is a steady-state nice-to-have).

> **2026-05-02 attempt — original gate finding (kept for history):** triggered a known AuthZ denial (probe pod in `default` ns → `authzen-facade.app:8080`); the connection was correctly rejected at the L4 layer (wget timed out), confirming the policy fired. **However:** ztunnel logs at info AND debug levels emit `"connection complete"` only for **successful** connections; no `"RBAC: access denied"` / policy-decision / rejection event surfaced for the denied path. ztunnel's Prometheus metrics (`/15020/metrics`) expose `istio_tcp_connections_opened_total` with `response_flags` and full source/dest principal labels, but every counter on this cluster has `response_flags="-"` — denials don't increment a separate counter visible to Prometheus today. Conclusion at the time: gap unresolvable at debug. **Superseded by the 2026-05-03 update above** — TRACE level closes the gap.

> **Banked baseline (carried forward whenever 7c resumes):** ztunnel version `1.29.2` (≥ ADR-0010's 1.24 requirement); current SPIFFE-ID format `spiffe://cluster.local/ns/<ns>/sa/<sa>` confirmed via `istio_tcp_connections_opened_total` label values (e.g. `source_principal="spiffe://cluster.local/ns/app/sa/default"`, `destination_principal="spiffe://cluster.local/ns/spicedb/sa/spicedb"`). Existing AuthorizationPolicy resources to rewrite at cutover time: `app/{default-deny,allow-app-to-authzen-facade,allow-prometheus-to-authzen-metrics}` (3 today; spicedb/keycloak/openbao have none yet). PeerAuthentication today: PERMISSIVE in `istio-system/default` only (no per-namespace pin).

Replace Istio's built-in Citadel with SPIRE-issued workload SVIDs so the mesh and the rest of the platform speak one trust domain (`spiffe://secforge.local/...`). Tighten PeerAuthentication from PERMISSIVE to STRICT in the same change window — they're paired because STRICT only becomes safe once every legitimate caller is mesh-resident or covered by an explicit AuthorizationPolicy ALLOW, which is itself easier to validate once the mesh and platform share one trust domain.

**Prerequisites:** Phase 7 ✅ (Loki + Tempo make the cutover observable as it lands).

**Deliverables:**
- Istio configured to use SPIRE as external CA via SDS; built-in Citadel disabled
- All ztunnel-to-ztunnel mTLS now uses `spiffe://secforge.local/...` SVIDs
- AuthorizationPolicies in `app`, `keycloak`, `spicedb`, `openbao` namespaces rewritten from `spiffe://cluster.local/...` to `spiffe://secforge.local/...`
- PeerAuthentication tightened from PERMISSIVE to STRICT
- Every legitimate non-mesh caller (ingress-nginx, kubelet probes, openbao→postgres) covered by explicit AuthorizationPolicy ALLOW
- Verification: end-to-end browser→BFF→Keycloak→AuthZEN→SpiceDB flow still works under STRICT; non-mesh callers still reach their targets

**See:** [docs/05-claude-code-prompts/phase-07c-istio-spire-ca-and-strict.md](./docs/05-claude-code-prompts/phase-07c-istio-spire-ca-and-strict.md); Phase 6 follow-ups #1 and #2; [ADR-0010](./docs/02-decisions/0010-istio-ambient-vs-sidecar.md) for deferral rationale.

---

## Phase 7d — Rotation and housekeeping batch *(1 day)*
**Status: 🟨 Partial — 7d.1 + 7d.2 (prompt-doc scope) ✅ Complete 2026-05-02. Items 3–7 split out as separate follow-ups (see "Deferred items" below).**

Bundle of small rotation/housekeeping items that share infrastructure and can be done together cheaply.

**Prerequisites:** Phase 7 ✅.

**Deliverables (prompt-doc scope — 7d.1 + 7d.2 + docs):**
- ✅ **BFF `private_key_jwt` rotation runbook** ([`docs/03-runbooks/bff-key-rotation.md`](./docs/03-runbooks/bff-key-rotation.md)): step-by-step procedure for rotating the per-client RSA-2048 signing keys in `secret/data/keycloak/clients/<id>` against the corresponding Keycloak client's `jwt.credential.public.key` attribute. Includes manual + cron paths and rollback procedure.
- ✅ **Rotation script** [`infrastructure/keycloak/realms/rotate-bff-key.sh`](./infrastructure/keycloak/realms/rotate-bff-key.sh) — single-key atomic swap (single-key scheme matches Phase 6.10b bootstrap; multi-key JWKS overlap was scope-expansion-blocked). Brief BFF outage during rolling restart (~10s on local edition; verified manually 2026-05-02 — KV v2→3, new `kid` in startup logs, `/login` returns 302 with valid PAR `request_uri`).
- ✅ **Four staggered rotation CronJobs** [`infrastructure/keycloak/realms/cron/01-rotate-bff-key.yaml`](./infrastructure/keycloak/realms/cron/01-rotate-bff-key.yaml) — 90-day cadence per BFF, staggered across day 0 / 22 / 45 / 67 of each window. Only `bff-key-rotator-helloworld-bff` is enabled (suspend:false); the other three are pre-provisioned suspend:true and unsuspended when their target BFFs land in Phase 9+.
- ✅ **SpiceDB `datastore_uri` static-copy migration**: see [ADR-0023](./docs/02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md). Original VaultStaticSecret → VaultDynamicSecret plan was structurally blocked (SpiceDB Operator's `secretName` requires single Secret holding both PSK + datastore_uri; VSO can't compose multi-source rendered Secrets). Chose **Path B** — kept the VaultStaticSecret, added a 12h CronJob ([`infrastructure/spicedb/cron/spicedb-datastore-refresher.yaml`](./infrastructure/spicedb/cron/spicedb-datastore-refresher.yaml)) that re-populates `secret/data/spicedb/config` from the database engine + static PSK. CNPG-rotation desync at the consumer level is now closed; the OpenBao-side connection still requires operator re-bootstrap on direct CNPG password rotation (recovery procedure in [`spicedb-operations.md`](./docs/03-runbooks/spicedb-operations.md)).
- ✅ **OpenBao database role** [`infrastructure/openbao/database-roles/spicedb-readwrite.sh`](./infrastructure/openbao/database-roles/spicedb-readwrite.sh) — registers `database/config/secforge-spicedb` connection + `spicedb-readwrite` role; explicit per-object grants (Postgres 16 SQLSTATE 42501 blocks the role-membership pattern). SpiceDB schema migrations during operator upgrades require a temporary fallback to static creds (documented in `spicedb-operations.md`).
- ✅ **Static migration script archived** to [`infrastructure/vault-secrets-operator/archive/migrate-datastore-uri-to-openbao.sh`](./infrastructure/vault-secrets-operator/archive/migrate-datastore-uri-to-openbao.sh) with deprecation header.
- ✅ **Documentation**: ADR-0023 (new); ADR-0015 §"What we did NOT do" updated; `01-architecture/05-secrets-management.md` SpiceDB row updated; `spicedb-operations.md` Path B procedure + CNPG-rotation recovery + schema-migration sharp edge.

**Deferred items (split out as separate follow-ups, NOT in 7d.1 + 7d.2 scope):**
- ✅ **Transit unseal token TTL strategy** (Phase 7d Item 3 — Complete 2026-05-02). Chose option (b/c hybrid): `-period=720h` periodic tokens that auto-refresh on every USE. Main OpenBao's transit-unseal call at boot counts as use → cluster reboot within 30d keeps the token alive transparently. Cold-pause must exceed 30d before recovery script needed (vs prior 24h). Two-line change in `init-seal.sh` + `rotate-transit-token.sh`, plus comment update in `apply-seal.sh`. ADR-0009 § Known local gaps #4 documents the trade-off table; runbook updates in `openbao-seal-unseal.md` + `openbao-recovery.md`. Live token still has the original 24h TTL until next `rotate-transit-token.sh` run (operator action; can wait). Operator-backlog #4 closed.
- ✅ **OpenBao metrics auth** (Phase 7d Item 4 — Complete 2026-05-02). Switched from `unauthenticated_metrics_access = true` (NetworkPolicy-only) to bearer-token auth (NetworkPolicy + token). Added `metrics-policy.hcl` (read on `sys/metrics` only); `configure-metrics-auth.sh` mints a periodic token (`-period=720h -no-default-policy -policy=metrics-policy`) and writes it to K8s Secret `openbao/openbao-metrics-token`; ServiceMonitor consumes via `bearerTokenSecret` (Secret must live in same ns as the ServiceMonitor — discovered during apply); listener block flipped to `unauthenticated_metrics_access = false`; pods rolled in `openbao-2 → 1 → 0` order. Verified: unauth scrape returns 400 (cannot-forward-local-only — correct behavior); auth scrape returns 200; all 3 Prometheus targets `health: up` post-cutover. The cert-SAN issue (Prometheus discovers pods by IP, mkcert cert valid for Service DNS only) is a separate cloud-migration item — `insecureSkipVerify=true` retained for now. **Postscript 2026-05-05** (operator-backlog #26 closed): the renew-on-USE pattern is brittle under failure-mode lockout — a sustained scrape failure means USE doesn't refresh the token's period, so the token can age out even with Prometheus running. Recovery is to re-run `configure-metrics-auth.sh` (idempotent — rotates the token + overwrites the Secret); Prometheus picks up the new bearer token from its mounted-Secret file on next scrape without restart. Documented as a known recovery scenario in `docs/03-runbooks/openbao-recovery.md` § "Restore Prometheus metrics-scrape auth".
- ✅ **Wazuh agent hardening + redeploy** (Phase 7d Item 5 — Complete 2026-05-02). Reframed against the original prompt: instead of relaxing wazuh ns to PSS=privileged or chart-patching the agent template, deployed a STANDALONE hardened DaemonSet in a dedicated `wazuh-agent` ns with PSS=privileged. Manifests at `infrastructure/wazuh-agent/`. Hardening: `privileged: false`; `hostPID: false`; capabilities `[DAC_OVERRIDE, SETUID, SETGID]` only; image pinned by SHA256 digest (`sha256:085aac6…`); `seccompProfile: RuntimeDefault`; `fsGroup: 999`. Cross-ns NetworkPolicy + Kyverno ns exclusion + manager ingress allow. **Hardening trade-off:** no host-level process inventory or auditd integration (would need `SYS_PTRACE`, `AUDIT_READ` not in baseline-allowed caps). **Open issue:** `client.keys` doesn't persist across pod restarts — enrollment loop quirk. Tracked as operator-backlog #17 (Phase 7d.5).
- ✅ **Wazuh — Keycloak/OpenBao → log forwarding** (Phase 7d Item 6 — config in place 2026-05-02). Reframed against the original prompt: instead of source-side syslog forwarding (OpenBao 2.x's `syslog` audit device is `/dev/log`-only, not network), the agent's `<localfile>` blocks tail Keycloak + OpenBao pod logs from the host's `/var/log/pods/` tree (mounted at `/host/var/log/pods/`). Config in `infrastructure/wazuh-agent/03-configmap.yaml`'s ossec-supplements.xml; verified loaded at runtime. Manager-side custom decoders for the JSON formats deferred as operator-backlog #18 (Phase 7d.6). Event flow gated by Item 5's `client.keys` persistence (operator-backlog #17).
- ✅ **Wazuh OIDC federation with Keycloak** (Phase 7d Item 7 — scaffolding Complete 2026-05-02). Keycloak client `wazuh-dashboard` provisioned via `infrastructure/keycloak/clients/wazuh.sh` (kcadm-admin pattern; supersedes the grafana-style throwaway-client idiom). OpenBao policy + role + VSO binding at `infrastructure/wazuh/03-vso-binding.yaml` render `wazuh-oidc-vso` Secret in wazuh ns. Auth-mode flip script `configure-wazuh-oidc.sh` (operator runs to switch dashboard from admin/admin to OIDC SSO; reversible). Skipped vendor-chart patching — in-place reconfig + securityadmin.sh push is the operator-time path.

**See:** [docs/05-claude-code-prompts/phase-07d-rotation-housekeeping.md](./docs/05-claude-code-prompts/phase-07d-rotation-housekeeping.md) (prompt-doc scope only); [ADR-0023](./docs/02-decisions/0023-spicedb-datastore-uri-rotation-pattern.md) (SpiceDB datastore_uri rotation pattern); [docs/03-runbooks/bff-key-rotation.md](./docs/03-runbooks/bff-key-rotation.md); [ADR-0015](./docs/02-decisions/0015-secret-distribution-pattern.md) §"What we did NOT do" (datastore_uri caveat now resolved).

---

## Phase 8 — Privileged Access (Teleport) *(optional locally, 2 days)*
**Status: ✅ Complete (8a 2026-05-02, 8b prototype B 2026-05-03)**

Teleport Community for cert-based local access. Less critical locally (you have direct kubectl access via Docker Desktop), but valuable for developing the production access workflow.

**8a foundation ✅ Complete 2026-05-02** (1 signed commit) — `teleport` ns + CNPG `secforge-teleport-db-1` cluster (reserved for HA promotion, currently unused — chart is `chartMode: standalone` with PVC-backed sqlite) + Keycloak `teleport` client + 3 realm roles (`platform_admin`/`platform_developer`/`platform_viewer`) + MinIO `teleport-recordings` bucket (90d Object Lock attempt — see Known gap below) + OpenBao paths + VSO bindings (`teleport-oidc-vso`, `teleport-minio-vso`) + mkcert TLS cert.

**8b prototype B ✅ Complete 2026-05-03** — Helm release of `teleport-cluster` 18.7.6 + `TeleportGithubConnector` + 3 `TeleportRoleV7` (admin/developer/viewer) + browser SSO + tsh CLI login + `kubectl exec` interactive session recording → MinIO, all end-to-end verified with full audit chain (`session.start` event has `github_teams: [platform-admins]` → `roles: [admin]` → `kubernetes_groups: [system:masters]`). Helm values pin `auth.teleportConfig.auth_service.proxy_listener_mode: multiplex` (chart default `separate` makes CLI dial 127.0.0.1:3023 which the local port-forward doesn't expose). Shelved keycloak `TeleportOIDCConnector` CR deleted from cluster.

**Pivot from original plan:** Teleport CE does not support OIDC connectors (Enterprise-only feature; verified in operator logs and the [feature matrix](https://goteleport.com/docs/feature-matrix/)). The 8a foundation provisioned the Keycloak `teleport` client expecting it to be the IdP; in 8b we discovered the gap and pivoted to a `TeleportGithubConnector` against operator-controlled org `security-forge1` / team `platform-admins` → `admin` role. Cloud-edition cutover (CE → Enterprise at VPS time) restores the Keycloak OIDC path: `04-oidc-connector.yaml` is preserved on disk for that flip.

**Known gaps deliberately accepted** (documented in [ADR-0024 § Amendment 2026-05-03](./docs/02-decisions/0024-teleport-community-edition-local.md#amendment-2026-05-03--ce-has-no-oidc-pivot-to-github-oauth)):
1. `admin` role grants `kubernetes_groups: [system:masters]` — full cluster-admin equivalence via Teleport. Scope-down deferred to cloud cutover (where direct kubeconfig access is also removed) or to whenever a 2nd operator joins.
2. MinIO Object Lock on `teleport-recordings` was specified but is not actually enforced in the local-edition deploy — a compromised admin can delete their own recording. Cloud cutover gets S3 Object Lock.
3. Wazuh-side audit log forwarding deferred (Phase 7d follow-up). Audit events are queryable via Promtail → Loki today.
4. Single-replica auth+proxy. Loss of auth pod = no Teleport logins until it recovers (~1min). Operator falls back to direct kubeconfig (`docker-desktop` context) for local recovery; cloud removes that fallback.

**MFA posture:** GitHub.com governs the IdP-side factor (operator should enable TOTP on their GitHub account). Keycloak realm-side TOTP is unused locally. Compensating control = tightened session TTLs (8h admin / 12h developer / 24h viewer). At cloud-edition cutover, posture reverts to Keycloak-side TOTP (and eventually hardware FIDO2 per [ADR-0007](./docs/02-decisions/0007-totp-instead-of-passkeys-locally.md)).

**See:** [docs/05-claude-code-prompts/phase-08-teleport.md](./docs/05-claude-code-prompts/phase-08-teleport.md) · [ADR-0024](./docs/02-decisions/0024-teleport-community-edition-local.md) · [docs/03-runbooks/teleport-operations.md](./docs/03-runbooks/teleport-operations.md)

---

## Phase 9 — Hello World End-to-End *(2-3 days)*
**Status: ✅ Complete (2026-05-04)** — 9.1–9.10.5 checkpoint, 9.12 teardown, 9.13 verify-clean all done. Design doc retired; reference source preserved.

**Prerequisites (all four MUST be ✅ before Phase 9 can start):** Phase 6b-1 ✅ (api-auth library — Phase 9 is its first real consumer) · Phase 3 follow-up ✅ (kcadm-admin service-account pattern — Phase 9's user provisioning depends on it) · Fix-after-07 ✅ (closes audit findings that block Phase 9's design assumptions, e.g., F-APP-1/F-APP-2 vendor-neutral OIDC + secrets interfaces, F-ARCH-2 RLS strategy, F-ADR-3 DPoP `htu` canonicalization rule) · Phase 7 ✅ (observability stack live so Phase 9's flow visibility checks have somewhere to land).

The minimal demo proving the platform works — and then explicitly torn down. Hello World is **disposable proof-of-platform**, not a tenant. Phase 9.10.5 is a hard checkpoint where the human verifies every component is operational; Phase 9.12 then removes all Hello World workloads, users, relationships, secrets, and roles so Phase 10 starts on a clean cluster. The reference *source code* under `apps/helloworld-*` stays as the canonical integration pattern.

**Deliverables:**
- Frontend (static HTML/JS): "Hello, [user]" + secret-of-the-day
- Backend API: **uses the `apps/lib/api-auth/` library from Phase 6b** to validate JWT + DPoP and call AuthZEN — Phase 9 is the first real consumer of the pattern, treat it as the integration test
- Three test users (jason, alice, bob) in Keycloak
- Passkey login working over local HTTPS
- All flow visible in Wazuh and Tempo
- **9.10.5 checkpoint** — human signs off in PLAN.md that all positive flows, negative flows, and observability outputs are verified before teardown. Without sign-off, do not proceed.
- **9.12 teardown** — `infrastructure/helloworld/teardown.sh` (idempotent, committed) removes Hello World workloads, the `helloworld-bff` Keycloak client, test users (jason/alice/bob/test-bot), SpiceDB relationships, OpenBao paths, JWT auth role, and the `app.secforge.local` Ingress. Skeleton clients `proposal-forge-bff` / `project-tracker-bff` / `pm-bff` are preserved.
- **9.13 verification** — automated checks confirm zero residue: no Hello World workloads, users, relationships, clients, secrets, or roles remain. Phase 10 does not start until this is clean.

**Checkpoint sign-off:**
- [x] Date checkpoint passed: 2026-05-04
- [x] Verified by: Jason Upole (operator)
- [x] Screenshots: skipped by operator decision (durable artifacts are source code + ADRs + design doc)
- [x] 9.12 teardown ran: `infrastructure/helloworld/teardown.sh`
- [x] 9.13 verify-clean PASSED: `infrastructure/helloworld/verify-clean.sh`

**See:** [docs/05-claude-code-prompts/phase-09-hello-world.md](./docs/05-claude-code-prompts/phase-09-hello-world.md)

---

## Phase 10 — Integrate Proposal Forge and Project Tracker *(3-5 weeks)*
**Status: 🟨 In progress** — Project Tracker substeps started 2026-05-04 (10.1.1 audit) → 2026-05-05 (10.1.2 SpiceDB schema additions ✅).

Per-substep status (Project Tracker — `{N}=1`):
- 10.1.1 — Audit doc at `docs/01-architecture/apps/project-tracker.md`: ✅ Complete 2026-05-04
- 10.1.2 — SpiceDB schema additions + validator tests: ✅ Complete 2026-05-05 — `definition organization` + five `project_tracker/{project,pursuit,task,bl_request,opp_watch_query}` definitions added to `infrastructure/spicedb/schema.zed`; five new validator tests under `infrastructure/spicedb/tests/project-tracker/` pass; schema applied to live SpiceDB; all 9 tests (4 platform + 5 PT) green.
- 10.1.3 through 10.1.10 — ⬜ Open

Bring the two existing applications living at `C:\Users\jaupo\Projects\Proposal Forge` and `C:\Users\jaupo\Projects\Project Tracker` into the SecForge ecosystem. Both apps share the same stack (Node 20 + Express + TypeScript + Prisma + Postgres + React + Vite + Tailwind + shadcn/ui), so the integration playbook is identical for both — done sequentially: **Project Tracker first** (smaller, single-user, fewer outbound secrets), Proposal Forge second.

This is **not a rewrite**. Each app's product code stays. Their auth (Passport.js + JWT in cookies), their secrets (`.env`), and their infrastructure (local docker-compose Postgres) are replaced.

**Per-app deliverables (executed twice — once for Project Tracker, once for Proposal Forge):**
- Audit doc at `docs/01-architecture/apps/{APP}.md` mapping the existing app onto the platform
- SpiceDB schema additions (`organization`, `proposal`, `project`, `pursuit`, `task`) + validator tests
- Postgres schema migration into `secforge-app-db` (per-app schema with RLS); existing data imported via `pg_dump` → transform → `psql`
- Local auth ripped out (Passport, JWT signing, login/register/logout routes, password storage); replaced with `apps/lib/api-auth/` middleware reading BFF-injected identity + AuthZEN checks
- Outbound secrets (Anthropic, OpenAI, Google AI, GSA, etc.) moved into OpenBao via `apps/lib/secrets/`; the `.env` file deleted from the repo, pre-commit guardrails from `templates/app-repo/` installed
- Containerized + Cosign-signed; deployed as `{APP}-server` Deployment with its own `{APP}-bff` (built from `apps/helloworld-bff/` source)
- Ingress at `pf.secforge.local` / `pt.secforge.local`
- Observability wiring: Grafana dashboard, Wazuh rules, end-to-end Tempo trace
- Local docker-compose stack decommissioned after 1 week of in-cluster verification
- Per-app CLAUDE.md updated to reflect platform-integrated state (Project Tracker's "no Anthropic API calls in backend" rule and Proposal Forge's provider-agnostic AI rule preserved)

**See:** [docs/05-claude-code-prompts/phase-10-integrate-proposal-forge-project-tracker.md](./docs/05-claude-code-prompts/phase-10-integrate-proposal-forge-project-tracker.md)

---

## Phase 11 — Develop Additional Apps *(open-ended)*
**Status: ⬜**

The platform now hosts both shipping apps. Phase 11 is the generic "build a new app" checklist — used for the future PM app (`pm-bff` skeleton client already exists in Keycloak from Phase 3) and any further products. Each new app:
- Registers as a Keycloak client (per-API audience, see Phase 6b)
- Gets its own BFF instance (or shares one with virtual-host routing)
- **Uses the `apps/lib/api-auth/` library from Phase 6b for all backend API auth** — no app reinvents JWT/DPoP/AuthZEN validation
- Defines its SpiceDB schema additions
- Stores its data in `secforge-app` Postgres (each in its own schema)
- Sends logs/metrics/traces to the observability stack (audit-log shape per Phase 6b)
- Follows the integration pattern proven by Phase 10

**See:** [docs/05-claude-code-prompts/phase-11-develop-apps.md](./docs/05-claude-code-prompts/phase-11-develop-apps.md)

---

## After Phase 11

When you're ready to leave local:

- **Going to a VPS / homelab**: see `docs/06-reference/migration-to-vps.md`. About 80% of your config moves unchanged.
- **Going to AWS**: see `docs/06-reference/migration-to-aws.md`. Apply the AWS-edition phase prompts; most of your work is replacing local Postgres pods with RDS, MinIO with S3, file-based KMS with AWS KMS, mkcert CA with Let's Encrypt.
- **Adding hardening for production**: regardless of destination, walk the hardening checklist (the HTML planning workspace) and run pen-test tools against staging before public exposure.

This local edition deliberately omits production-only concerns. Don't try to skip the hardening pass when you go live.

---

### Path decision (2026-05-01)

**Choice: Path B — `ileonelperea/wazuh-helm` v1.2.10** (Helm, repo `https://ileonelperea.github.io/wazuh-helm`, App 4.14.4, MIT, last commit 2026-04-07).

**Rationale.** Cuts adaptation work roughly in half vs. upstream Kustomize. Chart ships built-in ingress, NetworkPolicy, single-replica `.enabled` flags per component, cert auto-generation, watchdog CronJob, security hardening (seccompProfile RuntimeDefault, drop ALL caps, allowPrivilegeEscalation false), credential rotation, and ordered startup init containers. 540-line values + 46 templates with visible ADRs in the changelog and active development. `dashboard.ingress.enabled` + `ingressClassName` slots into our ingress-nginx pattern directly. Single-maintainer (bus factor) is the real risk — mitigated by vendoring the chart into our git tree and the option to fork.

**Path A — `wazuh/wazuh-kubernetes` (Kustomize)** considered and rejected for this session: official upstream from Wazuh Inc., last commit 2026-04-27, but assumes Traefik IngressRouteTCP (3 resources + 1 middleware in `wazuh/base/`), master+worker StatefulSets, and external `wazuh-certs-tool.sh` cert generation. 6–8 kustomize patches needed (replace Traefik with ingress-nginx, single-replica indexer, drop worker, OIDC). Kept as fallback if Path B has a deal-breaker.

**Charts rejected outright:**
- `MaximeWewer/wazuh-operator + wazuh-cluster` — operator install adds permanent surface area for one feature.
- `morgoved/wazuh-1.0.22`, `promptlylabs/wazuh-0.0.8`, `danilonicioka/wazuh-0.1.0`, `rock8s/wazuh-0.1.0`, `csic/wazuh-0.1.0` — alpha-version (0.0.x/0.1.0) or older app version, no comparable feature surface.
- `iosifache/wazuh-manager-filebeat` — manager+Filebeat only, not full stack.

**Open issue both paths share:** neither has built-in Keycloak OIDC. Both need OpenSearch Security plugin YAML config to map `platform_admin` realm role → Wazuh `admin`. Path B exposes the security config via templates so the integration sits cleanly in chart values.
