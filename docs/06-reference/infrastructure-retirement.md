# `infrastructure/` → `platform/` retirement

`infrastructure/` is the **retired Local Edition** (Docker Desktop K8s,
`secforge.local`, mkcert, file-based keys). `platform/` is the **live
production deploy** (bare-metal k3s, `secforge.dev`, real certs,
`install-all.sh` orchestration).

The two trees were maintained in parallel for a while; the live system is
now `platform/` only. This doc tracks retiring `infrastructure/` subdir by
subdir so nothing edition-agnostic is lost on the way out.

> **Do not bulk-`rm` `infrastructure/`.** Some subdirs hold content with no
> platform/ equivalent yet (see "Genuine gaps"), one holds parked future
> work, and most have inbound references in `docs/`, ADRs, and even live
> `platform/` files that must be repointed first.

## Per-subdir status

| Subdir | Verdict | Notes |
|---|---|---|
| `wazuh/` | ✅ **Done** | Retired 2026-05-20. Decoder/rules/ISM migrated to `platform/components/07o`+`07p`; rules renumbered 100300-range. |
| `cert-manager/` | ✅ **Done** | Retired 2026-05-20 (pure local-edition config; platform has `components/cert-manager.sh` + `manifests/cert-manager/` + `values/cert-manager.yaml`). |
| `cloudnativepg/` | ✅ **Done** | Retired 2026-05-20. Platform has `components/cloudnativepg.sh`, `manifests/cnpg-system/`, per-component `*/02-cnpg-cluster.yaml`, `values/cloudnativepg.yaml`. Companion Local-Edition doc `postgres-instances.md` retired with it. |
| `ingress-nginx/` | ✅ **Done** | Retired 2026-05-20 (`values.yaml` only; platform has the full equivalent). |
| `lib/` | ✅ **Done** | Retired 2026-05-20. Two `api-auth/verify-*.sh` local-edition test scripts; the library itself lives in `apps/lib/`. |
| `minio/` | ✅ **Done** | Retired 2026-05-20 (values + bucket-bootstrap Job + NetworkPolicies; platform has `components/minio*.sh` + `manifests/minio/`). |
| `namespaces/` | ✅ **Done** | Retired 2026-05-20 with its companion Local-Edition doc `namespaces.md`. Bulk ns + quota/limit file; platform components self-create their namespaces. |
| `spire/` | ✅ **Done** | Retired 2026-05-20. values + ClusterSPIFFEID + a Go test-workload demo; platform has `components/spire*.sh` + `manifests/spire/` + `values/spire.yaml`. |
| `vault-secrets-operator/` | ✅ **Done** | Retired 2026-05-20. values + connection/auth + one-shot cutover scripts; platform has `components/vso-*.sh` + `manifests/vault-secrets-operator/`. |
| `wazuh-agent/` | ✅ **Done** | Retired 2026-05-20. Local-edition in-cluster DaemonSet — superseded by the host-resident agent (component 11); the platform copy `manifests/wazuh-agent/` remains pending component-11 sign-off. |
| `teleport/` | ✅ **Done** | Retired 2026-05-20. Teleport was stopped (Tailscale took its operator-access role) and `08-teleport.sh` was never implemented (an unfilled stub). Fully decommissioned: `infrastructure/teleport/`, `platform/components/08-teleport.sh`, the `teleport-operations.md` runbook, and every teleport mention in the platform MinIO/OpenBao manifests + README. ADR-0024 left as the historical decision record. |
| `cosign/` | ✅ **Done** | Retired 2026-05-20. `cosign.pub` was the local-edition image-signing key; not referenced anywhere in `platform/` (the platform `05-image-signature-verification` policy is a stub that will get its own key). |
| `istio/` | ⏸️ **Deferred** | Investigated 2026-05-20: coupled to **open Phase 7c-2 work** (operator-backlog #21). `01-04` values + `install.sh` are cleanly superseded, but `05-peer-auth-app-*` + `06-authz-default-deny` are the 7c-1 baseline #21 builds on, `authzpol-strict-7c2-draft/` is the parked 7c-2 prep, and live runbooks (`istio-authz.md`, `istio-peer-auth-tighten.md`) treat this tree as source-of-truth. **Retire as part of the 7c-2 closeout** — a partial retirement now would orphan the prep. |
| `keycloak/` | ✅ **Done** | Retired 2026-05-20. The local-edition Keycloak (secforge-tenants realm, local deploy config, client scripts, operator CRDs, key-rotation cron) is fully superseded by platform's keycloak (11 manifests + operator/ + realms/ + 7 components). One piece was live content — `image/` (the custom Keycloak image Dockerfile the production keycloak-cr builds from) — migrated to `platform/manifests/keycloak/image/`. |
| `kyverno/` | ✅ **Done** | Retired 2026-05-20. All 4 policies superseded: `no-secret-shaped-env` + `legacy-secret-env-expiry` migrated to `manifests/kyverno/policies/09`+`10` (e272919); `pod-security` → `01-pss-baseline` + `06-require-runasnonroot`; `verify-signatures` → `05-image-signature-verification`. `values.yaml` → `values/kyverno.yaml`. `tests/` (offline `kyverno test` fixtures) were coupled to the local-edition policy form (`app` ns) and retired with the dir; re-creating offline test coverage against the rescoped 09/10 platform policies is net-new work, not a migration. |
| `observability/` | ✅ **Done** | Retired 2026-05-20. Helm values, apply scripts, and the dashboard ConfigMap are superseded by `platform/manifests/observability/` + `values/` + the observability components (the 6 Grafana dashboards were migrated in 2207b4b). `13-alerting-rules.yaml`'s 8 app/security alerts (OpenBao/Keycloak/SpiceDB/Istio) — genuine content with no platform equivalent — migrated to `platform/manifests/observability/10-app-alerts.yaml`; 6 of the original 14 rules dropped (redundant / quota-dependent / tied to the retired guardrail pipeline — rationale in that file's header). |
| `openbao/` | ✅ **Done** | Retired 2026-05-20. Deploy config (01-10 yaml), the bootstrap/configure/init scripts, and 9 of 10 `policies/*.hcl` are superseded by platform's openbao (`manifests/openbao/` + `values/openbao*.yaml` + 6 `openbao*` components + `policies/`). The one infra-only policy — `app-template.hcl` (ADR-0013 §4's identity-templated per-app policy) — was parked in `platform/manifests/openbao/policies/_deferred/`; platform uses concrete per-app policies, so the template pattern is deferred, not live. Live platform/ comment refs repointed. |
| `grafana/` | ✅ **Done** | Retired 2026-05-20. The 6 dashboards migrated to `platform/manifests/observability/dashboards/` + installer `platform/components/07q-grafana-dashboards.sh`. |
| `secrets-guardrails/` | ✅ **Done** | Retired 2026-05-20. The real gap (the `no-secret-shaped-env-vars` admission policy) was migrated separately — see `kyverno/` row. The 2 CronJobs were broken local-edition scaffolding; a production guardrail-verifier gets a from-scratch LIVE-mode rebuild (operator-backlog #39). The `verify/` suite was retired with the dir (operator decision 2026-05-20). |
| `spicedb/` | ✅ **Done** | Retired 2026-05-20. The deploy config (CR, netpols, VSO binding, cron, operator bundle) is superseded by `platform/manifests/spicedb/`. The genuine content — `ecosystem-schema.zed` + `schema.zed` (the SpiceDB authorization model; the only `.zed` copies anywhere) + the `tests/` validation suite — was migrated to `platform/manifests/spicedb/`. **Follow-ups:** confirm against a live `zed schema read` whether `schema.zed` (the older helloworld/PT model) is still needed or fully superseded by `ecosystem-schema.zed`; and wire a platform schema-apply path (the local `apply-schema.sh`/`run.sh` were not ported — they need platform `zed` setup). The live SpiceDB already has its schema applied — this migration preserves the source of truth. |
| `valkey/` | ✅ **Done** | Retired 2026-05-20 with the helloworld demo. Not deployed in production; its only consumer was the helloworld demo BFF. |
| `helloworld/` | ✅ **Done** | Retired 2026-05-20. Phase-9 integration-demo provisioning; the demo was retired 2026-05-04 and is not in production. The app *source* under `apps/helloworld-*` stays as the integration reference. |
| `project-tracker/` | ✅ **Done** | Retired 2026-05-20. One local-edition `provision-db-and-bao.sh`; Project Tracker's production deploy will get platform-style provisioning like the other ecosystem apps. |

## Status — content gaps all resolved

**22 of 23 subdirs retired** (see the table). Every genuine-content item was
migrated into `platform/`, not lost: the Grafana dashboards, the two ADR-0013
Kyverno admission policies, the Keycloak custom-image Dockerfile, the
app/security PrometheusRule alerts, the OpenBao templated-policy artifact,
and the SpiceDB schema + validation tests.

**Remaining:** `infrastructure/istio/` only — deferred, it retires as part of
the Phase 7c-2 closeout (operator-backlog #21). Once that lands, the
`infrastructure/` tree is gone entirely.

Open follow-ups (none block the retirement):
- A production guardrail-verification CronJob — from-scratch LIVE-mode
  rebuild (operator-backlog #39).
- SpiceDB — confirm whether `schema.zed` (the older helloworld/PT model) is
  still needed against a live `zed schema read`; wire a platform
  schema-apply path (`apply-schema.sh`/`run.sh` were not ported).
- The Audit→Enforce flip of the two ADR-0013 Kyverno policies (#39).
- Residual Local-Edition prose/comment refs in `docs/` + `apps/` (#40).

## Landmine — do NOT delete

- **`istio/authzpol-strict-7c2-draft/`** — parked Phase 7c-2 prep
  (AuthorizationPolicy templates, baseline capture, the SPIRE-CA helm-values
  diff). `operator-backlog #21` consumes it. Keep until 7c-2 lands.

## Process per subdir (the wazuh playbook)

1. Content-diff the subdir against its `platform/` equivalent.
2. Migrate any edition-agnostic content (rules, policies, schemas,
   dashboards, test fixtures) into `platform/` first.
3. `grep -rln "infrastructure/<subdir>/"` — repoint every inbound reference
   in `docs/`, ADRs, and `platform/` (closed operator-backlog items are
   historical record — leave them).
4. `git rm` the subdir; commit the subdir + its repointing together.

Local-Edition reference docs that exist only to document a retired subdir
(`cluster-services.md`, `postgres-instances.md`, `namespaces.md` — all
removed) retire *alongside* it — they are Local-Edition content, not
repointed to `platform/`. The production equivalents are
`platform/README.md` + `install-all.sh`.

## Residual after the subdir deletions

Deleting the subdirs leaves stale `infrastructure/*` path mentions in prose
and comments elsewhere. Handled by type:

- **Live `platform/` config** — repointed as each subdir was retired (must
  be clean).
- **ADR / PLAN / closed operator-backlog references** — left as-is; they are
  point-in-time decision/phase records, not live pointers.
- **Architecture docs, runbooks, `apps/*/deploy/` comments** — still carry
  Local-Edition path mentions. Some runbooks (`spire-rotation.md`,
  `teleport-operations.md`) are themselves wholly Local-Edition and
  superseded by platform equivalents. This is a separate Local-Edition
  docs cleanup — tracked as operator-backlog #40.
