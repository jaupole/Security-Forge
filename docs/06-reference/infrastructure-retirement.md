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
| `cert-manager/` | 🟢 Superseded | `values.yaml` + `cluster-issuer.yaml`; platform has `components/cert-manager.sh` + `manifests/cert-manager/` + `values/cert-manager.yaml`. |
| `cloudnativepg/` | 🟢 Superseded | Cluster CRs + values; platform has `components/cloudnativepg.sh`, `manifests/cnpg-system/`, per-component `*/02-cnpg-cluster.yaml`, `values/cloudnativepg.yaml`. |
| `ingress-nginx/` | 🟢 Superseded | `values.yaml` only; platform has the full equivalent. |
| `lib/` | 🟢 Superseded | Two `api-auth/verify-*.sh` test scripts; the library itself lives in `apps/lib/`. |
| `minio/` | 🟢 Superseded | values + bucket-bootstrap Job + NetworkPolicies; platform has `components/minio*.sh` + `manifests/minio/`. |
| `namespaces/` | 🟢 Superseded | Bulk ns + quota/limit file; platform components self-create their namespaces. |
| `spire/` | 🟢 Superseded | values + ClusterSPIFFEID + a Go test-workload demo; platform has `components/spire*.sh` + `manifests/spire/`. |
| `vault-secrets-operator/` | 🟢 Superseded | values + connection/auth + one-shot cutover scripts (already has an `archive/`); platform has `components/vso-*.sh` + `manifests/vault-secrets-operator/`. |
| `wazuh-agent/` | 🟢 Superseded | In-cluster DaemonSet — superseded by the host-resident agent (component 11); see `platform/README.md` note on `07b-wazuh-agent.sh`. |
| `teleport/` | 🟢 Replaced | Teleport was stopped; Tailscale took its operator-access role. Separate cleanup: `platform/components/teleport.sh`, `cloudnativepg/clusters/teleport-db.yaml`, `minio/networkpolicy-from-teleport.yaml`. |
| `cosign/` | 🟡 Partial | One file: `cosign.pub`. Not referenced anywhere in `platform/`. Confirm it is the *local-edition* signing key (not the GHCR production verification key) before deleting. |
| `istio/` | 🟡 Partial | `01-08` values/policies superseded by `manifests/istio/`. **`authzpol-strict-7c2-draft/` is 🅿️ PARKED** — `operator-backlog #21` (Phase 7c-2) depends on it. Keep that subdir. |
| `keycloak/` | 🟡 Partial | 35 files — realm defs, client scripts, image build, operator CRDs, key-rotation cron. Needs a real content-diff against `platform/components/keycloak*.sh` + `manifests/keycloak/`. |
| `kyverno/` | 🟡 Partial | `policies/` likely superseded by `manifests/kyverno/policies/`; `tests/` fixtures + `kyverno-test.yaml` have no obvious platform home — confirm before deleting. |
| `observability/` | 🟡 Partial | Values superseded by `components/{prometheus,loki,tempo,promtail,otel-collector}.sh`; `dashboards/` + `13-alerting-rules.yaml` may be a gap (see below). |
| `openbao/` | 🟡 Partial | 8/10 `policies/*.hcl` already in `platform/manifests/openbao/policies/`. `app-template.hcl` + `vso.hcl` are not — confirm migrated/renamed/obsolete. Config scripts superseded by `components/openbao*.sh`. |
| `grafana/` | 🔴 Gap | 6 dashboard JSONs (`auth-events`, `authz-checks`, `platform-health`, `secret-access`, `secrets-guardrails`, `service-mesh`). No Grafana dashboard JSONs exist anywhere in `platform/`. Migrate before deleting. |
| `secrets-guardrails/` | 🔴 Gap | The guardrail verification suite (8 `verify/*.sh`) + 2 weekly CronJobs. No equivalent in `platform/`. Decide: migrate, or confirm the cron coverage was intentionally dropped. |
| `spicedb/` | 🔴 Gap | `schema.zed` + `ecosystem-schema.zed` — no `.zed` file exists in `platform/`. The schema may have moved to the Ecosystem app repos (`ecosystem.zed` in Member Hub); verify where the live SpiceDB schema is sourced before deleting. `tests/` fixtures also need a home. |
| `valkey/` | 🔴 Gap | `values.yaml` is the **only** Valkey config in the repo. No Valkey component/manifest/values in `platform/`. Valkey is the session store (CLAUDE.md); confirm how it is deployed in production before deleting. |
| `helloworld/` | 📦 App | Phase 9 integration-demo app provisioning. Belongs with `apps/helloworld-*`, not platform infra — separate decision. |
| `project-tracker/` | 📦 App | One `provision-db-and-bao.sh` for the Project Tracker app — app-level, not platform infra. |

## Genuine gaps — resolve before the dir can go

- **`valkey/`** — no production Valkey config exists. Either Valkey is deployed
  un-managed, or apps relying on it are still in hybrid-dev mode.
- **`secrets-guardrails/`** — the verification suite + weekly drift/verify
  CronJobs have no platform home. Losing the dir loses that coverage.
- **`grafana/dashboards/`** — 6 dashboards with no platform equivalent.
- **`spicedb/schema.zed` + `ecosystem-schema.zed`** — the authorization model.
  Confirm the live schema source first.
- **`openbao/policies/{app-template,vso}.hcl`** — confirm migrated or obsolete.
- **`kyverno/tests/`** — admission-policy test fixtures, no platform home.

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
