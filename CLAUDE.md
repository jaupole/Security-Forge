# CLAUDE.md — Project Context for Claude Code (Local Edition)

> **This file is read by Claude Code automatically every session.** It is the authoritative source of project context. Read this file first. When the human asks you to do something that conflicts with this file, point out the conflict and ask before proceeding.

---

## Project mission

Build a secure, open-source Identity and Access Management platform that runs entirely on a local Docker Desktop Kubernetes cluster, supporting three applications (Proposal Forge, Project Tracker, future PM app). The owner is a senior security developer who values security over convenience and is using local development to iterate on the apps before committing to a cloud destination.

## We are running LOCALLY, not in the cloud

This is the **Local Edition**. Every decision in this CLAUDE.md is calibrated for that. Specific implications:

- **Substrate**: Docker Desktop Kubernetes (single node, but treat it as a real cluster)
- **DNS**: `*.secforge.local` resolves to 127.0.0.1 via hosts file or local DNS
- **TLS**: mkcert local CA, trusted by the developer's browser; cert-manager issues from it
- **Cloud KMS**: replaced by file-based keys mounted as Secrets, OpenBao Transit for app-level crypto
- **Cloud IAM (AWS IAM, GCP service accounts)**: does not exist — workloads use SPIFFE-ID-bound OpenBao roles
- **Cloud object storage (S3)**: replaced by MinIO
- **Public DNS / Let's Encrypt**: not applicable
- **Public Sigstore Rekor for image signatures**: keyless flow not available without GitHub OIDC; use local Cosign keys

This is intentional, not a deficiency. We're optimizing for fast iteration on the application layer.

## How to work in this repository

1. **Read [PLAN.md](./PLAN.md) first.** It tells you which phase the project is currently in.
2. **Follow the current phase's prompt document** in `docs/05-claude-code-prompts/`. Each phase has a single document with a prompt the human will paste.
3. **Reference, don't duplicate.** All architecture decisions are in `docs/01-architecture/` and `docs/02-decisions/`. Reference docs in `docs/06-reference/`.
4. **Update PLAN.md as you complete phases.**
5. **Write decisions down.** Non-trivial choices become ADRs in `docs/02-decisions/`. Number sequentially.

## Architecture stack (committed decisions)

| Layer | Local Edition choice | Rationale / cloud equivalent |
|---|---|---|
| Kubernetes | Docker Desktop K8s | Local-first; cloud equivalent: EKS / GKE / AKS |
| Identity Provider | Keycloak (Apache 2.0) | Same as cloud edition |
| Authorization | SpiceDB | Same |
| Secrets | OpenBao | Same |
| Outbound Secret Sync | Vault Secrets Operator (VSO) | Renders OpenBao secrets to K8s Secrets for operator-owned/-shaped consumers (SpiceDB, AuthZEN façade). Direct-API via `apps/lib/secrets/` for first-class apps — see [ADR-0015](./docs/02-decisions/0015-secret-distribution-pattern.md). |
| Workload Identity | SPIRE | Same; `spiffe://secforge.local` trust domain |
| Service Mesh | Istio Ambient | Same |
| Privileged Access | Teleport Community | Optional locally |
| Browser Pattern | BFF | Same |
| Token Strategy | OAuth 2.1 + PAR + DPoP-bound | Same |
| Auth Factor | Passkeys + hardware keys for admin | Same; passkeys work on `*.secforge.local` over local TLS |
| Session Store | Valkey (BSD-3-Clause) | Same |
| Database | Postgres (in-cluster) | Cloud equivalent: RDS Postgres |
| Object Storage | MinIO | Cloud equivalent: S3 |
| KMS | OpenBao Transit + file keys | Cloud equivalent: AWS KMS / GCP KMS |
| TLS Certs | cert-manager + mkcert local CA | Cloud equivalent: cert-manager + Let's Encrypt |
| Image Signing | Cosign with local keys | Cloud equivalent: Cosign keyless via GitHub OIDC |
| Admission Control | Kyverno (relaxed in dev mode) | Same |
| SIEM | Wazuh (slim) | Same |
| Logs | Loki + Promtail | Cloud equivalent: Loki + Promtail (works the same) |
| Metrics | kube-prometheus-stack | Same |
| Traces | OpenTelemetry → Tempo | Same |
| IaC | Pure Helm + kubectl manifests | Cloud equivalent: Terraform + Helm |

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

- ❌ Adding `localhost`, `127.0.0.1`, or wildcard CORS origins to **non-development-explicit** configurations. Local development has its own dedicated configs that are clearly marked.
- ❌ Storing access tokens, refresh tokens, or session keys in browser localStorage or sessionStorage.
- ❌ Disabling certificate verification (`-k`, `--insecure`, `tls.InsecureSkipVerify = true`) anywhere except a clearly-named throwaway dev script.
- ❌ Generating long-lived (>24h) credentials of any kind, except where the architecture document explicitly approves it (e.g., realm signing keys with 90-day rotation).
- ❌ Granting `cluster-admin` or `*:*` RBAC to a service account.
- ❌ Implicit OAuth flow, ROPC password grant, or any OAuth 2.0 (non-2.1) flow for new clients.
- ❌ SMS as an MFA factor.
- ❌ Putting Keycloak's admin console on the same hostname/path as the public OIDC endpoints.

When you encounter one of these, flag it. Do not "fix" it silently.

## Local-specific gotchas to remember

These are easy to forget on local but cause real bugs:

1. **Passkeys require HTTPS or `localhost`.** Do not test passkey flows over plain HTTP, ever. The browser will silently downgrade or fail.
2. **`localhost` and `127.0.0.1` are first-class for WebAuthn.** `secforge.local` is not — it requires a trusted cert. mkcert makes this work.
3. **DPoP `htu` claim must match exactly.** If your local URL is `https://app.secforge.local:8443` but the BFF resolves it as `https://app.secforge.local`, validation fails. Pick one and stick with it everywhere.
4. **Docker Desktop's loopback is special.** Pods reaching the host use `host.docker.internal`. Be careful with hostnames in configs.
5. **Resource quotas matter even locally.** Without them, one component can starve the cluster.

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
| Current phase instructions | [docs/05-claude-code-prompts/](./docs/05-claude-code-prompts/) |
| Why we made a particular tech choice | [docs/02-decisions/](./docs/02-decisions/) |
| How a component works | [docs/01-architecture/](./docs/01-architecture/) |
| Operational procedures | [docs/03-runbooks/](./docs/03-runbooks/) |
| Migration paths off local | [docs/06-reference/migration-to-vps.md](./docs/06-reference/) and [migration-to-aws.md](./docs/06-reference/) |
| Glossary | [docs/00-getting-started/00-glossary.md](./docs/00-getting-started/00-glossary.md) |
| Which Claude model to use for which task | [docs/06-reference/claude-model-selection.md](./docs/06-reference/claude-model-selection.md) |

## Model selection (token-cost discipline)

This project explicitly optimizes for token cost. Both Claude instances (VS Code, WSL) MUST follow [docs/06-reference/claude-model-selection.md](./docs/06-reference/claude-model-selection.md) when choosing a model for a task or spawning a subagent. Short version: **Opus for "decide whether to do X," Sonnet for "do X and report," Haiku for "is X true right now?"** When spawning Agent subagents, default `model: "sonnet"` unless the subagent's task is itself a design / synthesis decision.

## Updating PLAN.md

PLAN.md has two places that record phase status: the **"Phase order — quick reference"** table near the top, and the per-phase **`**Status:**`** line inside each phase's detail block. **When a phase status changes, update BOTH in the same edit.** The quick-reference table is the at-a-glance source of truth; if it drifts from the detail blocks, the table is wrong by definition. Bump the "Last updated" date in the quick-reference header on every edit.

## Updating this file

When you (Claude Code) learn something about the project that future-you should know — a non-obvious convention, a pitfall, a "we tried this and it didn't work" — propose adding it here.
