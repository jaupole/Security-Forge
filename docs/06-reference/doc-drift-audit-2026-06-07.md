# Documentation Drift Audit — 2026-06-07

A full sweep of all SecForge-ecosystem documentation (Project Tracker excluded) against the
**live `secforge-prod` cluster**. Goal: zero production drift. Accurate docs are confirmed,
drifted docs are fixed in place, obsolete build-era docs are archived with tombstones, and
outdated ADRs are superseded in place (append-only).

**Ground truth:** the running cluster, probed read-only via `ssh secforge` → `sudo -n kubectl`
on 2026-06-07. See the [Cluster snapshot](#cluster-snapshot-2026-06-07) appendix. Any
manifest-vs-live *infrastructure* drift found during the sweep is logged to
[`operator-backlog.md`](./operator-backlog.md) — infra is not changed by this sweep.

## Verdict legend

| Verdict | Meaning |
|---|---|
| ✅ ACCURATE | Matches prod; no change. |
| ✏️ FIX | Factually drifted; edited in place to match the live cluster. |
| 🪦 ARCHIVE | Obsolete build-era/local-first; moved to `docs/99-archive/` + tombstone banner. |
| ⛔ SUPERSEDE | Outdated ADR; in-place Status banner only (never moved). |
| 🔗 LINK | References a deleted/moved doc; repointed or removed. |
| 🏗️ INFRA-DRIFT | Doc reflects declared intent but cluster diverges; logged to operator-backlog. |

---

## Cluster snapshot (2026-06-07)

Single Hetzner bare-metal k3s node `secforge-prod` — `65.21.25.40` — k3s `v1.31.14+k3s1`,
Ubuntu 24.04.4 LTS, kernel 6.17. 28 namespaces.

### Ingress = Istio gateways (no ingress-nginx, no Gateway-API HTTPRoute)

Two `Gateway` objects in `istio-ingress`:

- **`secforge-gateway`** — public.
- **`secforge-gateway-tailnet`** — operator-only (Tailscale). Enforced by Kyverno
  `admin-ingress-must-be-tailnet-only`.

VirtualService host map (public vs tailnet-only):

| Host | Surface | Gateway |
|---|---|---|
| `auth.secforge.dev` | Keycloak OIDC | public + tailnet |
| `portal.secforge.dev` | Tenant Portal | public + tailnet |
| `members.secforge.dev` | Member Hub | public + tailnet |
| `billing.secforge.dev` | Billing | public + tailnet |
| `qbo.secforge.dev` | QuickBooks webhooks | public + tailnet |
| `stripe-connect.secforge.dev` | Stripe Connect (ADR-0034, 36h old) | public + tailnet |
| `control.secforge.dev`, `admin.secforge.dev` | Operator/admin shell | **tailnet only** |
| `kc.secforge.dev` | Keycloak admin console | **tailnet only** |
| `bao.secforge.dev` | OpenBao | **tailnet only** |
| `grafana.secforge.dev` | Grafana | **tailnet only** |
| `wazuh.secforge.dev` | Wazuh dashboard | **tailnet only** |
| `pf.secforge.dev` | Proposal Forge | **tailnet only** (not yet public) |

No `teleport` namespace. No `ingress-nginx` namespace. Operator access is Tailscale.

### Component versions (live image tags)

| Component | Version |
|---|---|
| k3s | v1.31.14+k3s1 |
| Keycloak | custom signed `ghcr.io/jaupole/keycloak` (digest-pinned) + operator 26.3.3 |
| OpenBao | 2.5.4 (3 nodes + 1 seal node, transit auto-unseal) |
| SpiceDB | v1.51.1 (operator v1.24.0) |
| Istio | pilot 1.30.0-distroless (Ambient) |
| MinIO | RELEASE.2025-09-07T16-13-09Z |
| Velero | v1.18.0 (kopia maintenance) |
| Trivy | server/cli 0.69.3, operator 0.30.1 (ClientServer mode) |
| CloudNativePG | operator 1.29.1, Postgres 17.6-bookworm, barman-cloud plugin v0.12.0 |
| Kyverno | v1.18.0 |

### Storage classes

`local-path` (default), `topolvm-local` + `topolvm-provisioner` (topolvm.io), `minio-local`
(no-provisioner, Retain — dedicated partition), `wazuh-local` (no-provisioner, Retain —
dedicated partition).

### Kyverno ClusterPolicies (17, all Ready)

`admin-ingress-must-be-tailnet-only`, `default-sa-no-automount`, `disallow-default-namespace`,
`disallow-latest-tag`, `istio-ambient-gateway-backends`, `legacy-secret-env-expiry`,
`mutate-default-resources`, `no-secret-shaped-env-vars`, `pss-baseline`, `require-image-digest`,
`require-resource-limits`, `require-run-as-nonroot`, `restrict-image-registries`,
`trivy-scan-tmpdir-isolation`, `velero-exclude-spiffe-jwt-fsbackup`,
`verify-image-signature-secforge`, `verify-image-signature-vendors`.

### Keycloak realms

`platform` (operator/admin — `browser-webauthn-required`, mandatory passkeys) and
`secforge-tenants` (tenants — `browser-flexible`, password-or-passkey + optional 2FA). Both
realm-imports run from the custom Keycloak image. Keycloak admin is DB-only (no API/kcadm).

---

## Confirmed-drift hitlist (seed)

| Doc | Drift | Verdict |
|---|---|---|
| `CLAUDE.md` (SF) | Auth Factor "TOTP"; Privileged Access "Teleport"; no Istio ingress row; "three applications" | ✏️ FIX |
| `PLAN.md` (SF) | "Local Edition"; Teleport Phase 8 ✅; PF Phase 10 🟨 (PF is live); dead teleport-operations link | 🪦 ARCHIVE + replace w/ prod STATUS |
| `02-decisions/0024-teleport-*` | Teleport stopped → Tailscale | ⛔ SUPERSEDE (by ADR-0035) |
| *(missing)* Tailscale-for-operator-access | Decision made, never recorded | ➕ ADR-0035 |
| `02-decisions/0007-totp-*`, `0002-*` | Prod = mandatory passkeys / tenants flexible-flow | ⛔/posture note |
| `01-architecture/09-privileged-access` | Teleport-centric (49 hits); prod is Tailscale | ✏️ FIX |
| `03-runbooks/*` (keycloak-operations, wazuh-operations, operator-cheatsheet, new-app-bootstrap, bff-key-rotation, istio-authz, secrets-guardrails-monitoring) | `secforge.local` → `secforge.dev` | ✏️ FIX |
| `99-archive/00-getting-started/*`, `99-archive/05-claude-code-prompts/*` | Docker Desktop/WSL2/local build prompts | 🪦 ARCHIVE |
| `06-reference/{migration-to-aws,migration-to-vps,migration-keycloak-to-cognito,iam-oss-edition,iam-license-procurement-addendum}` | Alt-path planning, superseded by bare-metal | 🪦 ARCHIVE |
| `Proposal Forge/docs/*` (04-14) | Pre-ecosystem-integration design | per-file ✏️/🪦 |
| `02-decisions/README.md` | Status column drifted | ✏️ FIX |

---

## Systemic fixes applied (all live SecForge docs)

1. **SPIFFE trust domain** `spiffe://secforge.local` / `spiffe://secforge.dev` → **`spiffe://secforge.platform`** (the live SPIRE trust domain) across `01-architecture`, `03-runbooks`, `04-security`, `06-reference`. ADRs left as history. Mesh trustDomain stays `cluster.local`.
2. **App/ingress hostnames** `secforge.local` → **`secforge.dev`** across the same dirs (ADRs/archive untouched).
3. **Teleport → Tailscale** throughout: CLAUDE.md, PLAN.md, 00-overview, 09-privileged-access (rewritten), threat-model cells, runbook index, operator-backlog.
4. **Auth factor TOTP → passkeys**: CLAUDE.md, ADRs, iam-platform banner.
5. **Archived-path link repoint**: all links into `00-getting-started`/`05-claude-code-prompts`/migration/iam docs → `99-archive/…`; glossary → `06-reference/glossary.md`.

## Per-area verdicts

### Security Forge — top level
| Doc | Verdict | Note |
|---|---|---|
| `CLAUDE.md` | ✏️ FIX | Apps list, Tailscale, passkeys, Istio ingress row, SPIRE trust domain, tailnet gotcha, repointed links. |
| `PLAN.md` | 🪦+✏️ | Local-edition build plan archived; replaced with production-status snapshot. |
| `README.md` | ✏️ FIX | Archived-path links repointed. |

### Security Forge — 01-architecture
| Doc | Verdict | Note |
|---|---|---|
| `00-overview.md` | ✏️ REWRITE | Reframed local→production (substrate table, apps, ingress, cookie sessions, CNI). |
| `09-privileged-access.md` | ✏️ REWRITE | Teleport doc → Tailscale model. |
| `01-iam-platform`, `02-authorization`, `04-bff-pattern`, `05-secrets-management`, `06-workload-identity`, `07-service-mesh`, `08-observability` | ✏️ FIX | Dropped "Local Edition" title; added production-delta banner; SPIFFE/hostname strings fixed. |
| `06-api-pattern.md`, `01a-realm-to-app-matrix.md` | ✏️ FIX | Hostname/SPIFFE strings; Valkey is reference-pattern (noted). |
| `apps/project-tracker.md` | — SKIP | PT excluded. |
| `apps/proposal-forge.md` | ✏️ FIX | Hostname + archived-link repoint (see Phase 5). |

### Security Forge — 02-decisions (ADRs)
| Doc | Verdict | Note |
|---|---|---|
| `0024-teleport-*` | ⛔ SUPERSEDE | By ADR-0035; dead teleport-operations link de-linked. |
| `0007-totp-*` | ⛔ SUPERSEDE | By ADR-0036 (production posture). |
| `0035-tailscale-replaces-teleport.md` | ➕ NEW | Records the Tailscale decision. |
| `0036-production-authentication-factors-passkeys.md` | ➕ NEW | Records production passkey posture. |
| `README.md` | ✏️ FIX | Index status column reconciled; 0035/0036 added. |
| all other ADRs | ✅ + 🔗 | Content left as append-only history; archived-path *links* repointed only. |

### Security Forge — 03-runbooks
| Doc | Verdict | Note |
|---|---|---|
| `README.md` | ✏️ REWRITE | "Expected runbooks" replaced with accurate index of the 41 real runbooks. |
| `keycloak-operations.md` | ⚠️ BANNER | Heavy local-edition; production banner added; **full rewrite tracked in operator-backlog**. |
| `bff-operations`, `openbao-recovery`, `openbao-seal-unseal`, `spicedb-operations`, `spire-ca-rotation`, `spire-rotation` | ⚠️ BANNER | Dropped "Local Edition" title + production-delta banner. |
| all runbooks | ✏️ FIX | `secforge.local`→`secforge.dev`, SPIFFE→`secforge.platform`, dead links. |

### Security Forge — 04-security / 06-reference
| Doc | Verdict | Note |
|---|---|---|
| `04-security/threat-model.md` | ⚠️ PARTIAL | Teleport cells fixed; large point-in-time doc — **full production refresh tracked in operator-backlog**. |
| `06-reference/glossary.md` | ✏️ FIX | EKS→k3s, trust domain, Terraform/Valkey "in use" corrected; relocated from 00-getting-started. |
| `06-reference/README.md` | ✏️ REWRITE | Accurate index; migration/iam briefs pointed to archive. |
| `06-reference/operator-backlog.md` | ✏️ FIX | #21 trust-domain (`secforge.platform`) + teleport ns removed; #40 addressed. |
| `06-reference/operator-cheatsheet`, trackers (`host-hardening`, `api-security-status`, `infrastructure-retirement`) | ✅ + ✏️ | secforge.local fixed; trackers already current/accurate. |

### Security Forge — archived (`99-archive/`)
| Doc | Verdict | Note |
|---|---|---|
| `00-getting-started/*`, `05-claude-code-prompts/*`, `migration-to-{aws,vps}`, `migration-keycloak-to-cognito`, `iam-oss-edition`, `iam-license-procurement-addendum`, `PLAN-local-edition.md` | 🪦 ARCHIVE | Moved via `git mv` (+ tombstone banners + `99-archive/README.md`). |

### App repos (Proposal Forge, Member Hub, Control, Portal, ecosystem-auth/ui)
| Doc | Verdict | Note |
|---|---|---|
| *(Phase 5 — see below)* | | Processed after SecForge core commit. |

### .claude/ tooling (prod-fact tier)
| Doc | Verdict | Note |
|---|---|---|
| *(Phase 6 — see below)* | | Prod-fact files only; static OWASP/NIST refs untouched. |

### Top-level handoff docs
| Doc | Verdict | Note |
|---|---|---|
| *(Phase 5)* | | CENTRALIZED-LOGIN-HANDOFF, ECOSYSTEM-UI-PLAN/TRANSITION-HANDOFF. |

## Flagged for follow-up (tracked in operator-backlog)

Two large local-edition docs got a protective production banner now but warrant a dedicated full
rewrite (out of scope for a one-pass sweep): **`03-runbooks/keycloak-operations.md`** (~550 lines of
local-edition procedure) and **`04-security/threat-model.md`** (~800-line point-in-time analysis).
