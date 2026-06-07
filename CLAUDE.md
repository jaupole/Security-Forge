# CLAUDE.md — Project Context for Claude Code

> **This file is read by Claude Code automatically every session.** It is the authoritative source of project context. Read this file first. When the human asks you to do something that conflicts with this file, point out the conflict and ask before proceeding.

---

## Project mission

Build a secure, open-source Identity and Access Management platform that runs on a single public Hetzner bare-metal k3s node, supporting a multi-tenant ecosystem of applications (Ecosystem Portal + Control plane, Member Hub, Proposal Forge, and Project Tracker). The owner is a senior security developer who values security over convenience and runs the platform on a public node serving real traffic over real DNS and TLS.

## We are running on a single public Hetzner node

This is a single public bare-metal deployment. Every decision in this CLAUDE.md is calibrated for that. Specific implications:

- **Substrate**: Hetzner bare-metal k3s (single node at `65.21.25.40`, but treat it as a real cluster)
- **DNS**: `*.secforge.dev` resolves publicly to the node's public IP
- **TLS**: cert-manager issues real certificates from Let's Encrypt, trusted by every browser
- **KMS**: OpenBao Transit for app-level crypto
- **Cloud IAM (AWS IAM, GCP service accounts)**: does not exist — workloads use SPIFFE-ID-bound OpenBao roles
- **Object storage (S3)**: replaced by MinIO
- **Public DNS / Let's Encrypt**: real public DNS for `*.secforge.dev`; cert-manager issues from Let's Encrypt
- **Image signatures**: keyless Cosign via GitHub OIDC against the public Sigstore Rekor

The node is hardened: public SSH is closed (Tailscale-only) and operator/admin ingress is reachable only over the Tailscale tailnet (the `secforge-gateway-tailnet` Istio gateway, enforced by the Kyverno `admin-ingress-must-be-tailnet-only` policy). Public app surfaces (`auth`, `portal`, `members`, `billing`, `qbo`, `stripe-connect`) are internet-facing over real TLS.

## How to work in this repository

1. **Read [PLAN.md](./PLAN.md) first.** It is the production status snapshot — what is deployed and where. Open work lives in [docs/06-reference/operator-backlog.md](./docs/06-reference/operator-backlog.md).
2. **The platform build is complete and live.** The original phase-by-phase build prompts are archived at [docs/99-archive/05-claude-code-prompts/](./docs/99-archive/05-claude-code-prompts/) for history; day-to-day work is now feature and operations work against the running cluster.
3. **Reference, don't duplicate.** All architecture decisions are in `docs/01-architecture/` and `docs/02-decisions/`. Operational procedures in `docs/03-runbooks/`. Reference docs in `docs/06-reference/`.
4. **Keep PLAN.md and the trackers current** as deployed state changes.
5. **Write decisions down.** Non-trivial choices become ADRs in `docs/02-decisions/`. Number sequentially.

## Architecture stack (committed decisions)

| Layer | Choice | Rationale / cloud equivalent |
|---|---|---|
| Kubernetes | Hetzner bare-metal k3s (single node) | Self-hosted public node; managed-cloud equivalent: EKS / GKE / AKS |
| Identity Provider | Keycloak (Apache 2.0) | Same as cloud edition |
| Authorization | SpiceDB | Same |
| Secrets | OpenBao | Same |
| Outbound Secret Sync | Vault Secrets Operator (VSO) | Renders OpenBao secrets to K8s Secrets for operator-owned/-shaped consumers (SpiceDB, AuthZEN façade). Direct-API via `apps/lib/secrets/` for first-class apps — see [ADR-0015](./docs/02-decisions/0015-secret-distribution-pattern.md). |
| Workload Identity | SPIRE | Same; `spiffe://secforge.platform` trust domain (Istio mesh trustDomain is `cluster.local`) |
| Service Mesh | Istio Ambient | Same |
| Ingress | Istio ingress gateway (Ambient) | `secforge-gateway` (public) + `secforge-gateway-tailnet` (operator-only); replaced EOL ingress-nginx — see [ADR-0032](./docs/02-decisions/0032-istio-gateway-replaces-ingress-nginx.md). |
| Privileged Access | Tailscale (operator-access mesh) | Admin ingress is tailnet-only. Teleport was evaluated and stopped — see [ADR-0024](./docs/02-decisions/0024-teleport-community-edition-local.md) → [ADR-0035](./docs/02-decisions/0035-tailscale-replaces-teleport.md). |
| Browser Pattern | BFF | Same |
| Token Strategy | OAuth 2.1 + PAR + DPoP-bound | Same |
| Auth Factor | Passkeys (WebAuthn, RpId `secforge.dev`). Operator/admin (`platform` realm): mandatory passkey + recovery codes (`browser-webauthn-required`). Tenants (`secforge-tenants` realm): password-or-passkey + optional 2FA (`browser-flexible`). TOTP removed. | Supersedes the interim TOTP posture of [ADR-0007](./docs/02-decisions/0007-totp-instead-of-passkeys-locally.md). |
| Session Store | HttpOnly-cookie sessions (Keycloak-driven) for the ecosystem apps | Valkey was the planned store for the Go BFF pattern (helloworld reference, since torn down); not currently deployed. |
| Database | Postgres (in-cluster) | Cloud equivalent: RDS Postgres |
| Object Storage | MinIO | Cloud equivalent: S3 |
| KMS | OpenBao Transit | Cloud equivalent: AWS KMS / GCP KMS |
| TLS Certs | cert-manager + Let's Encrypt | Same in managed cloud |
| Image Signing | Cosign keyless via GitHub OIDC | Same in managed cloud |
| Admission Control | Kyverno | Same |
| SIEM | Wazuh (slim) | Same |
| Logs | Loki + Promtail | Cloud equivalent: Loki + Promtail (works the same) |
| Metrics | kube-prometheus-stack | Same |
| Traces | OpenTelemetry → Tempo | Same |
| IaC | Pure Helm + kubectl manifests | Managed-cloud equivalent: Terraform + Helm |

If you're tempted to introduce a tool not on this list, **stop and ask first**.

## Coding conventions

- **Languages**: Go for backend services and BFF; TypeScript/React for frontends; Python only when no Go alternative.
- **Indent**: 4 spaces Python, tabs Go (gofmt), 2 spaces TS/YAML/JSON.
- **No mocks in production paths.** Tests hit real local infrastructure (testcontainers OK; mocks only for genuinely external services that we won't have locally).
- **No secrets in code, ever.** Not even in tests, not even commented out, not even in `.env.example`. Use OpenBao for runtime secrets.
- **Every API call to a sensitive endpoint requires both:** (1) valid JWT/session, (2) authorization check against SpiceDB. Authentication ≠ authorization.
- **Every database query in multi-tenant tables must include the tenant_id filter, AND the table must have a Postgres RLS policy.** Defense in depth — same locally and in cloud.
- **HTTP responses set the same security headers as production** — strict CSP with nonces, HSTS preload max-age 2y (yes, even on local, so the production behavior matches), X-Content-Type-Options nosniff, X-Frame-Options DENY, Referrer-Policy, Permissions-Policy.

## Things that should NEVER happen

These are bright-line rules. They apply locally too — if anything, the local environment is where you build the muscle memory.

- ❌ Adding `localhost`, `127.0.0.1`, or wildcard CORS origins to **non-development-explicit** configurations. Any local-development overrides live in dedicated configs that are clearly marked and never ship to the public node.
- ❌ Storing access tokens, refresh tokens, or session keys in browser localStorage or sessionStorage.
- ❌ Disabling certificate verification (`-k`, `--insecure`, `tls.InsecureSkipVerify = true`) anywhere. Certs are real Let's Encrypt certs; there is no reason to skip verification.
- ❌ Generating long-lived (>24h) credentials of any kind, except where the architecture document explicitly approves it (e.g., realm signing keys with 90-day rotation).
- ❌ Granting `cluster-admin` or `*:*` RBAC to a service account.
- ❌ Implicit OAuth flow, ROPC password grant, or any OAuth 2.0 (non-2.1) flow for new clients.
- ❌ SMS as an MFA factor.
- ❌ Putting Keycloak's admin console on the same hostname/path as the public OIDC endpoints.
- ❌ Storing outbound third-party credentials (Stripe, OpenAI, SendGrid, GitHub, etc.) in a `.env` file, an env var, a baked-in image layer, or an unencrypted-at-rest K8s `Secret`. They live in OpenBao at `secret/data/apps/<app>/<integration>` and are fetched at runtime via `apps/lib/secrets/`. The platform has six guardrail layers that reject any other path; see [ADR-0013](./docs/02-decisions/0013-outbound-secrets-no-env.md) and the runbook chain ([secrets-library.md](./docs/03-runbooks/secrets-library.md), [migrate-env-to-openbao.md](./docs/03-runbooks/migrate-env-to-openbao.md), [new-app-bootstrap.md](./docs/03-runbooks/new-app-bootstrap.md), [secrets-guardrails-verification.md](./docs/03-runbooks/secrets-guardrails-verification.md), [secrets-guardrails-monitoring.md](./docs/03-runbooks/secrets-guardrails-monitoring.md), [ci-secrets-check.md](./docs/03-runbooks/ci-secrets-check.md)). The expiring escape hatch (`secforge.dev/legacy-secret-env*` annotations) is the ONLY acceptable bypass and is itself time-bounded ≤90d with a tracked ticket reference.
- ❌ Defining environment variables whose names contain `KEY`, `SECRET`, `TOKEN`, `PASSWORD`, or `CREDENTIAL` on Pods in the `app` namespace. Kyverno admission denies them at deploy time. If a vendor SDK strictly requires this shape, use the escape hatch above with an expiry annotation.

When you encounter one of these, flag it. Do not "fix" it silently.

## Deployment gotchas to remember

These are easy to forget but cause real bugs:

1. **Passkeys require HTTPS.** Do not test passkey flows over plain HTTP, ever. The browser will silently downgrade or fail.
2. **WebAuthn needs a trusted cert.** `secforge.dev` works because cert-manager issues real Let's Encrypt certs; never fall back to a self-signed cert.
3. **DPoP `htu` claim must match exactly.** If the URL is `https://app.secforge.dev:8443` but the BFF resolves it as `https://app.secforge.dev`, validation fails. Pick one and stick with it everywhere.
4. **Operator/admin surfaces are tailnet-only; SSH is Tailscale-only.** Admin hosts (`control`, `admin`, `kc`, `bao`, `grafana`, `wazuh`, `pf`) route only through the `secforge-gateway-tailnet` Istio gateway. When a request or admin action is refused, check the Tailscale path and the tailnet gateway before assuming an app bug.
5. **Resource quotas matter on a single node.** Without them, one component can starve the cluster.

## Verification habits

After any change, before claiming "done":

1. **Run the relevant tests.** Go: `go test ./...`; TS: `npm test`; Helm: `helm lint && kubectl --dry-run=server apply`.
2. **Check security-relevant configurations.** CSP, RBAC, NetworkPolicy, AuthorizationPolicy, SpiceDB tuples.
3. **Update documentation.** Architecture changes → architecture doc. New decision → new ADR.
4. **Update PLAN.md status if a phase is complete.**

## Writing ADRs

ADRs are the project's append-only decision log. The numbering matters as much as the content — every reference like "see ADR-0012" must point at the same decision forever. Follow these rules:

1. **Always `ls docs/02-decisions/` before assigning a slot.** PLAN.md and prompt docs may reference future ADR numbers as intent ("ADR-0012 will cover X"), but the file system is the source of truth for which slots are taken. Don't trust planning references — confirm the actual highest-numbered file before writing.
2. **Reserve slots by writing a stub.** If you need to claim ADR-NNNN before its content is final, create the file immediately with header, `Status: In progress`, and a one-line description. Without a stub, the next ADR author may grab the number you intended.
3. **Filename convention is `NNNN-short-kebab-title.md`.** Match the existing pattern (e.g. `0011-bff-single-replica-local.md`). Don't introduce subletter conventions like `0011a-...` — they break sort order and signal that an ADR is "subordinate" to another, which conflates separate decisions.
4. **One ADR = one decision.** If you find yourself writing "and also" in an ADR title, you probably need two ADRs. The whole point is that future readers can grep for the specific decision.
5. **If you discover a slot collision while writing, stop and ask.** Don't silently renumber across docs — the user needs to confirm the rename scope before sed runs across the repo. Show the grep output of every reference first.
6. **PLAN.md and prompt docs reference ADRs by number, not by title.** When renumbering, grep for `ADR-NNNN` patterns; titles drift, numbers don't.

## Communication

- When you finish a phase, summarize what you built in 5–10 bullets.
- When you make a decision the human should know about, state it explicitly ("I chose X over Y because Z").
- When something fails, show the actual error and propose the next step.
- The human is doing this part-time. Default to assuming they have to come back in 3 days and need context.

## Where to find things

| You need... | Look in... |
|---|---|
| The plan | [PLAN.md](./PLAN.md) |
| The build history (archived phase prompts) | [docs/99-archive/05-claude-code-prompts/](./docs/99-archive/05-claude-code-prompts/) |
| Why we made a particular tech choice | [docs/02-decisions/](./docs/02-decisions/) |
| How a component works | [docs/01-architecture/](./docs/01-architecture/) |
| Operational procedures | [docs/03-runbooks/](./docs/03-runbooks/) |
| Open follow-ups not yet cleared | [docs/06-reference/operator-backlog.md](./docs/06-reference/operator-backlog.md) |
| Migration paths to managed cloud (archived alt-paths) | [docs/99-archive/migration-to-vps.md](./docs/99-archive/migration-to-vps.md) and [migration-to-aws.md](./docs/99-archive/migration-to-aws.md) |
| Glossary | [docs/06-reference/glossary.md](./docs/06-reference/glossary.md) |
| Which Claude model to use for which task | [docs/06-reference/claude-model-selection.md](./docs/06-reference/claude-model-selection.md) |

## Model selection (token-cost discipline)

This project explicitly optimizes for token cost. Both Claude instances (VS Code, WSL) MUST follow [docs/06-reference/claude-model-selection.md](./docs/06-reference/claude-model-selection.md) when choosing a model for a task or spawning a subagent. Short version: **Opus for "decide whether to do X," Sonnet for "do X and report," Haiku for "is X true right now?"** When spawning Agent subagents, default `model: "sonnet"` unless the subagent's task is itself a design / synthesis decision.

## Updating PLAN.md

PLAN.md is the **production status snapshot** — the deployed-state summary and the app/surface map. Keep it current as deployments change; detailed open work and follow-ups live in [docs/06-reference/operator-backlog.md](./docs/06-reference/operator-backlog.md). The original phase-by-phase build plan (local edition) is archived at [docs/99-archive/PLAN-local-edition.md](./docs/99-archive/PLAN-local-edition.md).

## Updating this file

When you (Claude Code) learn something about the project that future-you should know — a non-obvious convention, a pitfall, a "we tried this and it didn't work" — propose adding it here.
