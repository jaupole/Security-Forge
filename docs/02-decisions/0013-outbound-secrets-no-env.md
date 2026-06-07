# ADR-0013: Outbound secrets — no `.env`; OpenBao via SPIFFE-JWT

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

Phase 9/10 will accumulate apps that talk to third-party services — Stripe, OpenAI, SendGrid, SAM.gov, GitHub, eventually a long tail more. Without an authoritative policy stated up-front, the default path is `.env` files: easy to author, easy to accidentally commit, and easy to bake into images. Every previous secret-management horror story we don't want to repeat begins with a `.env` file.

[ADR-0015](./0015-secret-distribution-pattern.md) established the asymmetric VSO vs. direct-API split for **bootstrap** credentials (per-app `private_key_jwt` keys, SpiceDB preshared key). [ADR-0019](./0019-secret-distribution-interface.md) formalized the `SecretBootstrapper` interface that first-class apps consume. Neither ADR covers **outbound third-party credentials**, which is the larger surface area Phase 9/10 will introduce.

This ADR closes that gap. It crystallizes the policy *before* the Phase 6b-2 implementation lands so the library extension and guardrail stack are reviewed against a fixed target rather than co-evolving with the code.

## Decision

Outbound third-party credentials are subject to seven mandates. They apply to every SecForge app — first-class (BFF, future Phase 9/10 apps) and operator-shaped (SpiceDB, AuthZEN façade) — without exception.

### 1. Storage location

Outbound third-party credentials MUST live in OpenBao at the KV-v2 path `secret/data/apps/<app>/<integration>`, where:

- `<app>` is the per-app SPIFFE-ID short name (e.g., `proposal-forge`, `helloworld-bff`).
- `<integration>` is the third-party service identifier (e.g., `stripe`, `openai`, `sendgrid`, `samgov`).

Static credentials (API keys, OAuth client secrets, signing keys) live at this path. **Dynamic** credentials with rotation guarantees (e.g., per-request Postgres roles via OpenBao's database engine) live at `database/creds/<app>-<role>` and are returned with lease metadata so callers can `Revoke()` on completion.

### 2. Auth path

Apps fetch outbound credentials via **SPIFFE-JWT auth** (OpenBao's `auth/jwt/login` endpoint) using the JWT-SVID written to the pod's filesystem by `spiffe-helper`. No K8s ServiceAccount tokens, no shared API tokens, no static OpenBao tokens baked into images. The SPIFFE-ID's bound role's templated policy (see § 4 below) authorizes the read.

### 3. Forbidden carriers

Outbound third-party credentials MUST NOT appear in:

- `.env` / `.env.*` files (any name)
- Container env vars (`ENV` directives in Dockerfiles, `env` blocks in Pod specs)
- ConfigMaps
- Kubernetes Secrets in the `app` namespace (post-cutover; legacy non-`app`-ns Secrets out of scope)
- Source control (any branch, any history depth)
- Image layers (build-time `COPY .env` / `COPY . .` patterns)
- Application logs, error messages, panic stacks, Sentry/Rollbar payloads

The forbidden-carrier list is enforced by the multi-layer guardrail stack (§ 6) — **policy alone is insufficient**; without enforcement, every Phase 9/10 app defaults to `.env` on Day 1 because `.env` is the path of least resistance.

### 4. Templated OpenBao policy

Per-app authorization is enforced via OpenBao's identity templating, not per-app handwritten policies. A single templated policy at `infrastructure/openbao/policies/app-template.hcl` substitutes the SPIFFE-ID's `metadata.app` attribute into both the static-KV path and the dynamic-credential role prefix:

```hcl
path "secret/data/apps/{{identity.entity.aliases.<jwt-mount-accessor>.metadata.app}}/*" {
  capabilities = ["read"]
}
path "database/creds/{{identity.entity.aliases.<jwt-mount-accessor>.metadata.app}}-*" {
  capabilities = ["read"]
}
```

An app whose SPIFFE-ID is `spiffe://secforge.local/ns/app/sa/proposal-forge` is bound to an OpenBao JWT role with `token_metadata=app=proposal-forge`. The templated policy then authorizes only `secret/data/apps/proposal-forge/*` and `database/creds/proposal-forge-*` — cross-app reads are denied at the OpenBao policy layer, not just at the app layer. Verified by an explicit test workload that attempts a cross-app read and expects 403.

### 5. Library surface (`apps/lib/secrets/` extension)

The `SecretBootstrapper` interface ([ADR-0019](./0019-secret-distribution-interface.md)) handles **bootstrap-at-startup** reads. Outbound credentials are fetched repeatedly during request handling and need a different surface:

- **`Client`** — long-lived, holds the OpenBao address and per-app role binding, exposes `GetField(ctx, integration, field)` for static creds and `GetDynamic(ctx, role)` for leased credentials. Constructor takes a `Config` struct with `Hardened bool` (see § 7).
- **In-memory cache** with configurable TTL (default 5 minutes). Cache miss triggers fresh fetch and re-auth if the cached client token has expired. TTL refreshes happen in the background; in-flight calls return the cached value.
- **`DynamicCredential`** — the return type of `GetDynamic`. Carries lease ID and `Revoke(ctx)` method. The lease is renewed-or-revoked by the caller when the borrowed connection lifecycle completes.
- **`Close()`** — zeroes in-memory secret bytes (best-effort; Go's GC makes guarantees impossible, but the intent is documented).

The library is an **extension** of the existing `apps/lib/secrets/` package — adapter and bootstrap interface stay identical; outbound is additive. New files (`outbound.go`, `secret.go`, `cache.go`) sit alongside `bootstrapper.go` and `openbao.go`. Single `apps/lib/go.mod`. No new submodule. The interface seam for compliance-cutover migrations remains the `SecretBootstrapper` shape from ADR-0019; future AWS Secrets Manager / GCP Secret Manager adapters extend the same package.

### 6. Multi-layer prevention guardrails (defense in depth)

Policy without enforcement is decoration. Outbound-credential leak prevention is implemented as a **five-layer stack** (six counting the runtime scrubber), and a credential leak requires defeating all of them:

| Layer | Mechanism | Scope |
|---|---|---|
| 1 — Pre-commit | gitleaks + custom `block-env-files` + `block-secret-shaped-vars` hooks | Developer machine, advisory (can be `--no-verify`-bypassed) |
| 2 — CI | Same checks mirrored in GitHub Actions; cannot be bypassed without admin merge | Auditable (every PR) |
| 3 — Build-time | Trivy `--scanners secret` configured to **fail** (not warn); hadolint rejects `COPY .env*` patterns | Image manifests |
| 4 — Admission | Kyverno `no-secret-shaped-env-vars` ClusterPolicy in **Enforce** mode; matches env names containing `*KEY*`, `*SECRET*`, `*TOKEN*`, `*PASSWORD*`, `*CREDENTIAL*` in the `app` namespace | Cluster, every Pod admission |
| 5 — Runtime | `apps/lib/secrets/` `Hardened` mode + `Secret` type with `String()`/`MarshalJSON()` redaction + `Use()` accessor pattern | Application memory |
| 6 — Error reporting | `apps/lib/errreport/` scrubber (Section 6 of the prompt) wired into a no-op `Reporter` sink in 6b-2; Phase 7 swaps the sink to Sentry/Rollbar without touching the scrubber | Outbound error payloads |

Each layer captures a different attack surface. Pre-commit catches the careless author. CI catches `--no-verify`. Build-time catches the developer who commits a non-`.env` file containing a secret. Admission catches the Pod authored outside the template entirely. Runtime catches the secret successfully fetched but accidentally `fmt.Printf`-ed. The scrubber catches a secret value reaching an outbound error payload (Sentry/Rollbar context dictionary, panic stack).

Every layer's bypass emits a structured `secrets.guardrail.bypass` event ([Section 8 of the Phase 6b-2 prompt](../99-archive/05-claude-code-prompts/phase-06b-2-outbound-secrets.md) defines the schema). Phase 7 ingests these via Promtail / Loki and adds Grafana dashboard + Alertmanager rules.

### 7. `Hardened` mode and runtime hygiene

The `Hardened` field on `secrets.Config` is the explicit posture toggle:

- **`Hardened: true`** (default for new apps): `GetField` does NOT return `string` — it returns `Secret` (a `[]byte` wrapper with redaction-aware `String()` / `MarshalJSON()`). Callers MUST use `Use(func(b []byte) error)` or the bundled helpers (`HTTPHeader(secret)`, `BasicAuth(user, secret)`, `DSN(template, secret)`) to interact with the value. After `Use` returns, the library best-effort-zeroes the slice.
- **`Hardened: false`** (transitional): `GetField` returns `string` directly. This path exists solely so existing apps (none today; will accumulate as Phase 9/10 lands) can adopt the library without simultaneously refactoring every call site. Migration to Hardened is a per-app PR.

#### Hardened-mode rollout plan

1. New apps default to `Hardened: true`. The library's constructor warns at non-Hardened init: `secrets: Hardened mode disabled — see ADR-0013 for migration plan` (severity high, emitted as a `secrets.guardrail.bypass` event so it appears in the same dashboard).
2. Existing apps remain non-Hardened until explicitly migrated. Each migration is a per-app PR exercising every Hardened-incompatible call site.
3. **Migration target: pre-AWS-migration (latest acceptable date).** Once all in-cluster apps are Hardened, the library default flips to Hardened-everywhere, the warning becomes a hard error at non-Hardened construction, and the non-Hardened code path is removed in a single subsequent commit.

The library refuses to log via `slog` / `log` directly; any internal logging passes through a redaction-aware logger that masks any value the library returned. This is enforced by package-internal lint, not by convention.

### 8. Self-expiring escape hatch

There are integrations whose vendor SDKs read a specific env var name (e.g., `STRIPE_API_KEY`) and refuse to accept the credential any other way. For those, and only those, an **expiring escape hatch** is the only acceptable carrier:

```yaml
metadata:
  annotations:
    secforge.local/legacy-secret-env: "JIRA-1234"           # required: ticket ref
    secforge.local/legacy-secret-env-expires: "2026-07-30"  # required: ISO date, max 90d out
```

A second Kyverno ClusterPolicy (`legacy-secret-env-expiry`) enforces:

1. If `legacy-secret-env` is present, `legacy-secret-env-expires` MUST also be present.
2. `expires` MUST parse as an ISO date.
3. `expires` MUST be ≤ 90 days from admission time.
4. `expires` MUST be in the future at admission time.

A daily CronJob scans existing Pods carrying the annotation pair and emits `secrets.guardrail.bypass` events with `severity=high` for any expiring within 14 days. Operators see the warning in Grafana before the Pod is denied admission on its next deploy.

The escape hatch is **not** a permanent home for any secret. Each use is a tracked debt with a hard deadline.

### 9. VSO-compatible path scheme (worked example)

The `secret/data/apps/<app>/<integration>` scheme is deliberately Vault Secrets Operator-renderable. First-class apps consume directly via `apps/lib/secrets/`, but if a future workload ships as an operator-owned chart whose consumer only reads K8s Secrets, VSO can render the same path without us reorganizing OpenBao. Worked example for a hypothetical operator-owned consumer in the `app` namespace:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: proposal-forge-stripe
  namespace: app
spec:
  type: kv-v2
  mount: secret
  path: apps/proposal-forge/stripe
  destination:
    name: proposal-forge-stripe-creds
    create: true
  refreshAfter: 5m
  vaultAuthRef: proposal-forge-vault-auth
```

The KV path `apps/proposal-forge/stripe` is exactly what `apps/lib/secrets/` reads via `GetField(ctx, "stripe", "api_key")` — no reorganization needed. This compatibility is the litmus test: any path scheme the library uses MUST be representable as a `VaultStaticSecret` `path` field, no exceptions. This rules out path patterns that depend on substitution at read time, request-bound paths, etc.

### 10. Inbound webhook receiver authentication

`apps/security-events-collector/` (the HTTP service that ingests `secrets.guardrail.bypass` events from CI runners and Kyverno) authenticates inbound calls and **overrides** the payload-claimed `actor` field with the verified caller identity before logging the event:

- **In-cluster callers** (Kyverno, library hygiene checks, image-build pipeline running in-cluster) authenticate via SPIFFE-SVID. The collector reuses [`apps/lib/api-auth/`](../01-architecture/06-api-pattern.md) middleware (from Phase 6b-1) to verify the SVID and resolve the caller identity.
- **Out-of-cluster callers** (CI runners outside Docker Desktop) authenticate via a short-lived JWT issued by a dedicated Keycloak client `security-events-ci`.
- **Unauthenticated requests** are rejected with HTTP 401 and emit their own `secrets.guardrail.bypass` event with `severity=high` so silent rejection doesn't mask an attacker probing the endpoint.

The `actor` override closes a "trust the payload" weakness: a compromised CI runner cannot launder identity by claiming to be a different actor in the event payload.

## What this ADR explicitly does NOT cover

- **Inbound M2M / Tier 5 — third-party access to our APIs.** OAuth 2.1 `client_credentials` with `private_key_jwt`, separate Keycloak client per integration. Out of scope for 6b-2; scheduled for the first time we actually need it. Tracked as a known follow-up in [PLAN.md](../../PLAN.md) Phase 6b-2 § Known follow-ups.
- **Bootstrap credentials** (per-app `private_key_jwt` keys, SpiceDB PSK, BFF private keys at startup). Covered by [ADR-0015](./0015-secret-distribution-pattern.md) and [ADR-0019](./0019-secret-distribution-interface.md). The Phase 6b-2 library extension does not change the `SecretBootstrapper` interface.
- **Rotation runbooks** for individual third-party credentials. Each integration's rotation cadence is defined when the integration lands; ADR-0013 only mandates that rotation MUST be possible without redeploying any app (i.e., callers MUST tolerate a fresh value on cache refresh).
- **Compliance-cutover adapter implementations** (AWS Secrets Manager, GCP Secret Manager). The interface seam from ADR-0019 + this ADR's outbound surface is designed to accommodate them; concrete implementations land at compliance-cutover time.
- **`AuthZEN façade` migration to direct-API.** AuthZEN remains operator-shaped (VSO-rendered K8s Secret) per ADR-0015. ADR-0013's library is for first-class consumers; AuthZEN's migration path is a separate decision deferred until rotation cadence demands it.

## Open questions (carried forward)

- **`AuthZEN` migration trigger.** Same as ADR-0015's open question — revisit when AuthZEN's load profile demands rotation faster than VSO's 60s refresh OR when a third-party-credential need surfaces in AuthZEN itself.
- **Hardened-mode flip date.** "Pre-AWS-migration" is the latest-acceptable bound; the actual flip is gated on every in-cluster app having migrated. Track the migration count in PLAN.md as Phase 9/10 apps adopt the library.
- **Trivy + secret-detection false positives.** Trivy's secret scanner has known false-positive patterns for some credential shapes (notably internal-only pre-shared keys that happen to match high-entropy regex). The fail-on-finding posture means a false positive blocks a build; the operational answer is to add the false positive to `trivyignore` with a ticket reference and a 30-day review. We will track FP frequency for the first 90 days and revisit if the noise rate is operationally hostile.

## Re-evaluation triggers

- A new app's secret-loading needs an operation neither `GetField` nor `GetDynamic` cleanly serves → propose a third method on `Client`, OR a sibling type. Do NOT bolt on a method that returns adapter-specific concepts (lease ID, ARN, tag) via the public Client surface.
- A real attempt to leak an outbound credential succeeds despite all six guardrail layers → the failure mode informs which layer needs deepening, and this ADR's "Multi-layer prevention guardrails" table gets a seventh row.
- The Hardened-mode warning emits more than ~2 events per week post-cutover → migration to Hardened-everywhere is overdue; revisit the rollout-plan deadline.
- The scrubber rule set drops a known secret prefix (e.g., a new vendor's credential format) → add the prefix and re-fuzz; document the addition here.

## Cross-references

- [ADR-0014 — API auth library design](./0014-api-auth-library-design.md) — the library that secures inbound API calls; complements this ADR's outbound surface.
- [ADR-0015 — Secret distribution pattern (VSO + direct-API)](./0015-secret-distribution-pattern.md) — the asymmetric split this ADR builds on.
- [ADR-0019 — Secret distribution interface (`SecretBootstrapper`)](./0019-secret-distribution-interface.md) — the bootstrap interface; ADR-0013 is the outbound-credential extension.
- [Phase 6b-2 prompt](../99-archive/05-claude-code-prompts/phase-06b-2-outbound-secrets.md) — the runnable phase that implements this ADR.
- [PLAN.md § Phase 6b-2](../../PLAN.md) — phase tracking, follow-ups, success criteria.
- CLAUDE.md "Things that should NEVER happen" — the corresponding bright-line rule lands in CLAUDE.md as part of Phase 6b-2 commit 6.

## References (post-implementation, populated as commits land)

- `apps/lib/secrets/outbound.go` — `Client` type and outbound surface (commit 1b)
- `apps/lib/secrets/secret.go` — `Secret` wrapper + `Use()` accessor (commit 1b)
- `apps/lib/secrets/cache.go` — TTL cache (commit 1b)
- `infrastructure/openbao/policies/app-template.hcl` — templated per-app policy (commit 1b)
- `apps/lib/errreport/` — scrubber + no-op sink (commit 2)
- `templates/app-repo/` — repo-template guardrails (commit 3)
- `infrastructure/kyverno/policies/no-secret-shaped-env.yaml` — admission guardrail (commit 4)
- `infrastructure/kyverno/policies/legacy-secret-env-expiry.yaml` — escape-hatch validator (commit 4)
- `apps/security-events-collector/` — webhook receiver (commit 4)
- `infrastructure/secrets-guardrails/verify/run-all.sh` — eight-case verification suite (commit 6)
- `docs/03-runbooks/secrets-library.md` + five other runbooks (commit 6)
