# SecForge Platform — Production Status

The platform is **built and live** on a single public Hetzner bare-metal k3s node (`secforge-prod`,
`65.21.25.40`), serving real traffic on `*.secforge.dev` over real Let's Encrypt TLS. This page is
the production status snapshot. Open work and follow-ups live in
[docs/06-reference/operator-backlog.md](./docs/06-reference/operator-backlog.md).

> The original phase-by-phase **local-edition build plan** (Docker Desktop / WSL2) is archived at
> [docs/99-archive/PLAN-local-edition.md](./docs/99-archive/PLAN-local-edition.md). The build is complete;
> day-to-day work is now feature and operations work against the running cluster.

**Last updated:** 2026-06-07 (documentation drift sweep — see
[docs/06-reference/doc-drift-audit-2026-06-07.md](./docs/06-reference/doc-drift-audit-2026-06-07.md)).

## Substrate

- k3s `v1.31.14+k3s1` on Ubuntu 24.04, single node, `65.21.25.40`.
- Operator access: **Tailscale** (public SSH closed). Admin ingress is tailnet-only.
- Ingress: **Istio ingress gateway** (Ambient) — `secforge-gateway` (public) + `secforge-gateway-tailnet`
  (operator-only). No ingress-nginx, no Teleport.

## Deployed surfaces

| Host | App / surface | Exposure |
|---|---|---|
| `auth.secforge.dev` | Keycloak OIDC | public |
| `portal.secforge.dev` | Ecosystem Portal (tenant shell) | public |
| `members.secforge.dev` | Member Hub | public |
| `billing.secforge.dev` | Billing | public |
| `qbo.secforge.dev` | QuickBooks Online webhooks | public |
| `stripe-connect.secforge.dev` | Stripe Connect (ADR-0034) | public |
| `control.secforge.dev` / `admin.secforge.dev` | Ecosystem Control / operator-admin shell | tailnet-only |
| `kc.secforge.dev` | Keycloak admin console | tailnet-only |
| `bao.secforge.dev` | OpenBao | tailnet-only |
| `grafana.secforge.dev` | Grafana | tailnet-only |
| `wazuh.secforge.dev` | Wazuh dashboard | tailnet-only |
| `pf.secforge.dev` | Proposal Forge | tailnet-only |

Apps not yet deployed: **Project Tracker** (PM app — schema/identity provisioned, app not live).

## Platform components (live versions)

| Layer | Component | Version |
|---|---|---|
| Identity | Keycloak (custom signed `ghcr.io/jaupole/keycloak`) + operator | operator 26.3.3 |
| Realms | `platform` (operator, mandatory passkeys) + `secforge-tenants` (tenant, flexible flow) | — |
| Authorization | SpiceDB (operator v1.24.0) | v1.51.1 |
| Secrets | OpenBao (3 + 1 seal, transit auto-unseal) | 2.5.4 |
| Outbound secret sync | Vault Secrets Operator | — |
| Workload identity | SPIRE — trust domain `secforge.platform` | — |
| Service mesh | Istio Ambient — mesh trustDomain `cluster.local` | pilot 1.30.0 |
| Database | CloudNativePG / Postgres | operator 1.29.1 / pg 17.6 |
| Object storage | MinIO (dedicated partition, SSE-S3) | RELEASE.2025-09-07 |
| KMS | OpenBao Transit | — |
| Admission | Kyverno (17 ClusterPolicies) | v1.18.0 |
| Image signing | Cosign keyless (GitHub OIDC, cosign v2 pin — see backlog #90) + `verify-image-signature-*` policies. Identity = the fleet reusable workflow ref (ADR-0040) | — |
| App CI/CD | Fleet `reusable-image-build.yml` (all 6 app repos are thin callers) + one-command `deploy-app.yml` (digest bump + deploy-from-git via sudoers-gated box wrapper; ADR-0040, runbook `deploy-app-image.md`) | live 2026-06-11 |
| Backup/DR | Velero + kopia | v1.18.0 |
| SIEM | Wazuh (manager + indexer, dedicated partition) | — |
| Vuln scanning | Trivy Operator (ClientServer) | operator 0.30.1 / trivy 0.69.3 |
| Observability | Loki + Promtail, kube-prometheus-stack, Tempo (OTel) | — |
| Storage classes | local-path (default), topolvm-local/provisioner, minio-local, wazuh-local | — |

## Where to look

| You need… | Look in… |
|---|---|
| How a component works | [docs/01-architecture/](./docs/01-architecture/) |
| Why a tech choice was made | [docs/02-decisions/](./docs/02-decisions/) |
| Operational procedures | [docs/03-runbooks/](./docs/03-runbooks/) |
| Open follow-ups | [docs/06-reference/operator-backlog.md](./docs/06-reference/operator-backlog.md) |
| Trackers (hardening, API security, infra retirement) | [docs/06-reference/](./docs/06-reference/) |
| The build history | [docs/99-archive/](./docs/99-archive/) |
