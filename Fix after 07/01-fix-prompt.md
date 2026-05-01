# Fix-after-07 — single-prompt remediation

> **You are Claude Code working in `c:/Users/jaupo/Projects/Security Forge/`.**
> **Project:** SecForge — local Kubernetes IAM platform (Docker Desktop K8s, Keycloak, SpiceDB, OpenBao, SPIRE, Istio Ambient).
> **User profile:** senior security developer, not a full-stack developer. Cybersecurity specialist. Default to extra explanation when proposing code changes; ask before destructive operations; show the diff before applying.
>
> **Context document:** Read `Fix after 07/00-audit-findings.md` in full before doing anything else. The findings are referenced below by ID (e.g. F-ORD-1). Do not re-audit; trust the findings file unless you encounter evidence that contradicts it (in which case, stop and tell the user).

---

## Pre-flight (do these first, in order)

### 0.1 — Verify Phase 7 is fully ✅ before proceeding
Run:
```bash
grep -E "^## Phase 7" PLAN.md | head -5
kubectl get pods -n observability
kubectl get pods -n wazuh
```
Confirm all of:
- PLAN.md `Phase 7` line shows `✅` (not `🟡`)
- All Phase 7 sub-tasks (7.0.a soak verified, 7.0.b, 7.0.c, 7.1–7.7) marked done in PLAN.md
- `observability` ns has loki, promtail, tempo, otel, prometheus, grafana, alertmanager all Running
- `wazuh` ns has manager + indexer + dashboard + agent DaemonSet, OR the user explicitly says Wazuh is deferred indefinitely

If any of these is not satisfied: **stop and ask the user** whether to proceed anyway (some fixes will be unverifiable without Loki/Tempo).

### 0.2 — Read the audit findings
Read `Fix after 07/00-audit-findings.md` end-to-end. Make a TodoWrite list mirroring the section structure below (one todo per section, not per finding — finer granularity creates noise).

### 0.3 — Branch
```bash
git status                 # confirm clean working tree
git checkout -b fix-after-07
```
If the working tree is dirty, **stop and ask** — do not stash silently.

### 0.4 — Confirm operator decisions
Show the user this list and ask each as a single question, accept yes/no/defer:

1. **Phase numbering / filenames.** Plan: do NOT renumber; add navigation headers. Confirm?
2. **`test-spire` namespace** (F-CLU-4). Empty for 36+ hours. Plan: delete it. Confirm or defer?
3. **`wazuh` namespace** (F-CLU-5). Plan: if Wazuh was deployed in Phase 7 Session 2 → leave; if deferred indefinitely → delete. Which?
4. **Kyverno `verify-image-signatures` mode** (F-CLU-6). Plan: stay in Audit per ADR-0004. Confirm?
5. **Phase 6b-1 design questions** (F-ORD-1, ADR-0012 lines 76–83). Plan: this prompt does NOT resolve them; it adds a BLOCKING marker to PLAN.md and Phase 9. Confirm?
6. **Phase 3 follow-up scheduling** (F-ORD-5). Plan: move it to run BEFORE Phase 9, not after Phase 7. Confirm or override?
7. **ADR-0021 reservation update (2026-05-01):** ADR-0021 has been reserved for Git initialization + commit-signing strategy (discovered 2026-05-01 during Phase 6b-1 documentation work — project has no git repo). The kcadm-admin Phase 3 follow-up ADR moves to **ADR-0022**. Confirm.
8. **Image-signing key custody ADR** (F-ADR-12). Plan: this prompt does NOT auto-write — flag in PLAN.md as a blocker for the supply-chain phase. Confirm?

Record the answers. Cite them in commit messages.

---

## Section A — App-code coupling refactors (F-APP-1 through F-APP-4, F-APP-6)

> **Goal:** introduce `apps/lib/` with three minimal-but-complete interfaces so future backend swaps don't force app rewrites. The user's stated goal: "easy transition to a compliant security backend, without full redesign."
>
> **Order matters:** create the libs first (compile-tested in isolation), then swap call sites in `helloworld-bff` and `authzen-facade`, then run the apps to verify behavior is unchanged.

### A.1 — Establish `apps/lib/` (F-APP-6)
Create:
```
apps/lib/
├── go.mod                  # module = github.com/secforge/apps-lib (or matching whatever helloworld-bff/go.mod uses for replace directives)
├── README.md               # one paragraph: this is the shared lib root for first-class apps
├── oidc/
├── secrets/
└── authzn/
```
Use `go mod init` from the directory. Decide module path by reading `apps/helloworld-bff/go.mod` first to match the project's existing import style. **If unclear, ask the user.**

Add a top-level `apps/lib/README.md`:
```markdown
# apps/lib — shared libraries for first-class SecForge apps

This directory holds vendor-agnostic interfaces wrapping security backends
(OIDC IdP, secret store, authorization engine). Apps under `apps/*` import
from here so a future backend swap (Keycloak→Cognito, OpenBao→AWS Secrets
Manager, SpiceDB→Cedar) does not require app code rewrites.

| Package | Interface | Current adapter | ADR |
|---------|-----------|-----------------|-----|
| `oidc`  | `Provider` | Keycloak | (Phase 6 design + this fix prompt) |
| `secrets` | `SecretBootstrapper` | OpenBao | ADR-0019 |
| `authzn` | `AuthZN` | SpiceDB | (Phase 4 + this fix prompt) |

Adapter selection is by build tag or factory function — see each subpackage README.
```

### A.2 — `apps/lib/oidc/` (F-APP-1, F-APP-2)
Define the interface:
```go
// apps/lib/oidc/provider.go
package oidc

import "context"

type Claims struct {
    Subject           string
    PreferredUsername string  // may be empty depending on issuer
    Email             string
    SessionState      string  // Keycloak-specific; empty for Cognito etc.
    Roles             []string
    Raw               map[string]any  // escape hatch for issuer-specific claims
}

type Provider interface {
    // ParseIDToken validates and returns claims from a raw id_token string.
    ParseIDToken(ctx context.Context, rawIDToken string) (*Claims, error)
    // KidFor returns the issuer-expected `kid` value for a given public key.
    KidFor(pubKeyDER []byte) string
}
```

Add `apps/lib/oidc/keycloak.go` implementing `Provider` for Keycloak. Move:
- The DER-SHA256 `kid` derivation from `apps/helloworld-bff/oidc.go:53–68` into `KidFor`.
- The `Claims` struct binding from `apps/helloworld-bff/proxy.go:92–101` into `ParseIDToken`.

Add a `keycloak_test.go` that asserts: given a sample id_token (from a fixture, **never** a real one), `ParseIDToken` returns the expected Claims. The test must run with `go test ./...` from `apps/lib/`.

### A.3 — `apps/lib/secrets/` (F-APP-4, F-ADR-10)
Define:
```go
// apps/lib/secrets/bootstrapper.go
package secrets

import "context"

type SecretBootstrapper interface {
    // GetClientKey returns the BFF private_key_jwt key bytes for the configured client.
    GetClientKey(ctx context.Context) ([]byte, error)
    // GetKV returns the value at the given path (KV-style retrieval).
    GetKV(ctx context.Context, path string) ([]byte, error)
}
```

Add `apps/lib/secrets/openbao.go` implementing `SecretBootstrapper` against OpenBao's HTTP API. Move the SPIFFE-bound JWT login + KV-v2 read from `apps/helloworld-bff/openbao.go` into here.

The constructor takes config:
```go
func NewOpenBaoBootstrapper(addr string, jwtPath string, role string, clientKVPath string) (SecretBootstrapper, error)
```
No package-level state. No env-var reads inside the lib (the app reads env vars and passes config in).

### A.4 — `apps/lib/authzn/` (F-APP-3)
Define:
```go
// apps/lib/authzn/authzn.go
package authzn

import "context"

type Decision struct {
    Allowed bool
    Reason  string  // optional; for audit logs
}

type Subject struct {
    Type string  // "user" | "service"
    ID   string
}

type Resource struct {
    Type string
    ID   string
}

type AuthZN interface {
    Evaluate(ctx context.Context, subject Subject, action string, resource Resource) (*Decision, error)
}
```

Add `apps/lib/authzn/spicedb.go` implementing `AuthZN` against SpiceDB. Move the `CheckPermission` call from `apps/authzen-facade/main.go:175` into here. Constructor:
```go
func NewSpiceDBAuthZN(endpoint string, presharedKey string, tlsCAPath string) (AuthZN, error)
```

### A.5 — Wire `helloworld-bff` to use the libs
Edit `apps/helloworld-bff/`:
- `oidc.go` — replace inline `kid` derivation and claim parsing with calls to `apps/lib/oidc/keycloak.NewProvider(...)`. The BFF still owns OAuth flow plumbing (PAR, callback, refresh); the lib owns provider-shape concerns.
- `openbao.go` — replace `bootstrapClientKey()` with a call to `apps/lib/secrets.NewOpenBaoBootstrapper(...).GetClientKey(ctx)`. Keep the env-var reads in `main.go` (lib doesn't read env).
- `proxy.go` — replace the inline Claims struct with `oidc.Claims` from the lib.

After each file edit: `go build ./...` from `apps/helloworld-bff/`. Must compile.

After all three: `go test ./...` from project root if tests exist; otherwise just build.

Run the BFF locally (or in-cluster) and walk through one OIDC login. Confirm it still works end-to-end. **Do not skip this step** — interface refactors look right and break silently.

### A.6 — Wire `authzen-facade` to use the libs
Edit `apps/authzen-facade/main.go`:
- Replace `*authzed.Client` field with `authzn.AuthZN` interface.
- Replace `s.client.CheckPermission(...)` at line 175 with `s.authzn.Evaluate(...)`.
- Build, deploy, run a CheckPermission round-trip via the existing `/readyz` health probe (which exercises the path).

### A.7 — Commit
```
git add apps/lib apps/helloworld-bff apps/authzen-facade
git commit -m "fix-after-07: extract OIDC, secrets, authzn interfaces (F-APP-1..4)"
```

---

## Section B — Cluster fixes (F-CLU-1, F-CLU-2, F-CLU-3, F-CLU-4, F-CLU-5)

### B.1 — OpenBao startupProbe (F-CLU-1, F-CLU-3)
Find the OpenBao StatefulSet manifest (`infrastructure/openbao/`). Add a startupProbe that checks for the SPIFFE socket file before allowing the main container to start:

```yaml
startupProbe:
  exec:
    command:
      - sh
      - -c
      - 'test -S /spiffe-workload-api/spire-agent.sock'
  failureThreshold: 30   # 30 retries × 10s = 5min grace for CSI registration
  periodSeconds: 10
  timeoutSeconds: 2
```
(Adjust the socket path to match what's actually mounted. Read the volume mount section of the manifest first; **don't guess the path**.)

Apply only to the OpenBao StatefulSets — `helloworld-bff` and `authzen-facade` already have HTTP startupProbes (audit verified this; PLAN.md 7.0.a's "6 workloads" claim is stale — only 4 OpenBao pods are missing them. Update PLAN.md when you reach Section D.)

Apply manifest, wait for rollout, run:
```bash
kubectl rollout status statefulset/openbao -n openbao
kubectl rollout status statefulset/openbao-seal -n openbao
```

**Soak test:** ask the user to do a Docker Desktop restart and confirm pods come back without manual `kubectl delete pod`. If they don't, the socket path is wrong — investigate, do NOT widen the failureThreshold.

### B.2 — AuthorizationPolicies for platform namespaces (F-CLU-2)
**Important coordination:** Phase 7c will flip PeerAuthentication PERMISSIVE→STRICT. This fix package must NOT flip the PeerAuthentication mode — only add AuthzPolicies. Phase 7c will need every legitimate caller to be either mesh-resident or covered by an AuthzPolicy ALLOW; this section is the prep work.

For each of these namespaces, create an AuthorizationPolicy file under `infrastructure/istio/authz/`:
- `keycloak/` — allow ingress-nginx → keycloak; allow nothing else from outside the ns (and from same-ns workloads)
- `spicedb/` — allow `app/authzen-facade` → spicedb; deny everything else
- `openbao/` — allow `app/helloworld-bff` SA + any other SPIFFE-IDed legitimate callers (read the existing OpenBao policies under `infrastructure/openbao/policies/` first to identify them); deny rest
- `observability/` — allow Promtail (DaemonSet) → Loki; allow Grafana → Loki/Prometheus/Tempo; allow Alertmanager → Prometheus; deny external
- `minio/` — allow only the workloads currently using MinIO (none yet expected; default-deny)
- `valkey/` — allow `app/helloworld-bff` SA; deny rest

Template (per-namespace `default-deny.yaml`):
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: <NS>
spec:
  {}   # empty selector + no rules = default deny
---
# explicit ALLOWs follow in sibling files; one file per ALLOW for diff clarity
```

For each ALLOW, use SPIFFE source identity, not service account name strings:
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-app-authzen-to-spicedb
  namespace: spicedb
spec:
  selector:
    matchLabels:
      app: spicedb
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/app/sa/authzen-facade"]
```

Apply one namespace at a time. After each, smoke-test that the workload can still reach its expected dependencies (Keycloak login, SpiceDB CheckPermission, OpenBao secret read). If anything 403s, the AuthzPolicy is too tight — read the audit log (Loki) and add a specific ALLOW for the legitimate caller.

**Do not apply all six at once.** One at a time, smoke-test, commit.

### B.3 — `test-spire` and `wazuh` namespace decisions (F-CLU-4, F-CLU-5)
Per the operator answers from §0.4. Examples:
- If delete: `kubectl delete ns test-spire` (and same for `wazuh` if applicable). Remove any references in `infrastructure/namespaces/` so `kubectl apply` doesn't recreate them.
- If keep: add a sentinel ConfigMap with a comment explaining why the ns exists (`kubectl -n <ns> create configmap purpose --from-literal=reason="..."`).

### B.4 — Commit
```
git add infrastructure
git commit -m "fix-after-07: openbao startupProbe + AuthzPolicies for platform ns (F-CLU-1, F-CLU-2)"
```

---

## Section C — ADRs and architecture docs (F-ADR-1 through F-ADR-11)

> **Operator note:** ADRs are append-only. Never edit a published ADR's decision section. If an ADR is wrong, write a new one that supersedes it.

### C.1 — Reserve and write ADRs 0016–0020
Create stubs first (CLAUDE.md ADR-numbering rule §2):
```bash
for n in 0016 0017 0018 0019 0020; do
  case $n in
    0016) title="token-and-credential-lifetimes" ;;
    0017) title="session-expiry-semantics" ;;
    0018) title="multi-tenancy-rls-strategy" ;;
    0019) title="secret-distribution-interface" ;;
    0020) title="openbao-backup-and-dr" ;;
  esac
  printf '%s\n' "# ADR-$n: ..." "Status: In progress" > "docs/02-decisions/$n-$title.md"
done
```
Then fill each one. Templates (each ADR follows the existing project format — read `docs/02-decisions/0014-*.md` and `0015-*.md` for the style):

#### ADR-0016 — Token and credential lifetimes (F-ADR-2)
Consolidate every TTL in one table:
| Credential | Issuer | TTL | Renewal | Source of truth |
|---|---|---|---|---|
| Keycloak access token | Keycloak | 5m | refresh | `01-iam-platform.md:135` |
| Keycloak refresh token (platform realm) | Keycloak | session-idle 15m × remember-me 30d | re-auth | `01-iam-platform.md` |
| Keycloak refresh token (secforge-tenants) | Keycloak | session-idle 30m, no remember-me | re-auth | `01-iam-platform.md` |
| Keycloak realm signing key | Keycloak | 90d | rotation runbook | `docs/03-runbooks/realm-signing-key-rotation.md` |
| SPIRE X.509-SVID | SPIRE Server | 1h | auto | `06-workload-identity.md:97` |
| SPIRE JWT-SVID | SPIRE Server | 5m | per-request | `06-workload-identity.md` |
| OpenBao JWT-auth token | OpenBao | 1h | re-auth via SVID | `05-secrets-management.md:115` |
| Cookie session (Valkey TTL) | BFF + Valkey | idle 30m, hard-cap 8h | per-request | `04-bff-pattern.md` |
| DPoP key (in-memory per pod) | BFF | pod lifetime | n/a | this ADR |
| Image signing key | Cosign | manual rotation | TBD | F-ADR-12 |

Decision: **all credential lifetimes documented in a single canonical table; any deviation requires a new ADR superseding 0016.**

Cross-link from `CLAUDE.md`, `docs/01-architecture/01-iam-platform.md`, `docs/01-architecture/05-secrets-management.md`, `docs/01-architecture/06-workload-identity.md`.

#### ADR-0017 — Session expiry semantics (F-ADR-8)
Lock in: cookie has `Max-Age` UNSET; Valkey TTL is sole authority; idle-timeout 30m, hard-cap 8h. Document the silent-401 failure mode and how the BFF should handle it (re-prompt for login, not error).

#### ADR-0018 — Multi-tenancy RLS strategy (F-ADR-9)
Decision: every multi-tenant Postgres table MUST have:
1. A `tenant_id UUID NOT NULL` column.
2. A row-level security policy `USING (tenant_id = current_setting('app.tenant_id')::uuid)`.
3. The application connection sets `SET LOCAL app.tenant_id = '...'` per request inside a transaction.
4. SpiceDB authorization runs *before* the query — Postgres RLS is defense-in-depth, not the primary check.

Provide an example RLS policy in the ADR (do not commit migration code yet — that comes in Phase 9).

#### ADR-0019 — Secret distribution interface for first-class apps (F-ADR-10)
Document the `apps/lib/secrets/SecretBootstrapper` interface created in Section A.3. Reference ADR-0015 (which split operator-owned vs first-class). State that future KMS adapters (AWS Secrets Manager, Vault Enterprise) implement the same interface.

#### ADR-0020 — OpenBao backup and DR (F-ADR-11)
Decisions to make explicit:
- Raft snapshot frequency: every 6h locally; every 1h in cloud (referenced).
- Snapshot storage: `/data/backups/openbao/` on the host, retained 30 days. Cloud: object storage with lifecycle.
- Recovery procedure: high-level steps (full runbook deferred to a follow-up).
- Recovery key custody: file-based locally (per ADR-0009); HSM/KMS in cloud. Recovery shamir threshold preserved.
- RTO target: 1h. RPO target: 6h locally, 1h cloud.

The ADR is the *decision*. The runbook is a follow-up — flag it in PLAN.md as a Phase 5 follow-up that this fix package opened.

### C.2 — Update CLAUDE.md (F-ADR-1)
Edit the Architecture stack table:
```markdown
| Auth Factor | TOTP (interim — see ADR-0007) + recovery codes; passkeys + hardware FIDO2 at production hardening | Same; passkeys work on `*.secforge.local` over local TLS |
```

### C.3 — Architecture doc updates
- `docs/01-architecture/04-bff-pattern.md` line 281 — change "fresh 16-byte random nonce" to "fresh 16-byte cryptographically random nonce via `crypto/rand.Read`. The nonce is added to the request context and included in CSP violation reports for traceability." (F-ADR-4)
- `docs/01-architecture/02-authorization.md` line 8 — add a banner above the inline schema:
  ```markdown
  > **Canonical source:** [`infrastructure/spicedb/schema.zed`](../../infrastructure/spicedb/schema.zed). The schema below is a copy for reference; do NOT edit here. Update the canonical file and resync this doc.
  ```
  (F-ADR-7)
- `docs/01-architecture/00-overview.md` — add a "Network policy contract" section: every namespace MUST have a default-deny-ingress NetworkPolicy; explicit ALLOWs documented in component sections. Cite F-ADR-6 / verification command.
- `docs/03-runbooks/keycloak-operations.md` — add a "Verifying claim plumbing with the Keycloak Evaluate tool" section. Include: (1) where to find the Evaluate tool in the admin UI (Realm → Clients → [client] → Client scopes → Evaluate), (2) which output panes show which token (userinfo, id_token, access_token), (3) how to read multivalued claims like `realm_access.roles`, (4) what "claim is in Evaluate output but not consumed downstream" implies (downstream defect, not Keycloak misconfig — see Phase 7.0.b investigation as the canonical example). This section is reusable: any future "missing claim" debug should start with the Evaluate tool before assuming Keycloak is at fault.

### C.4 — Extract DPoP `htu` canonicalization (F-ADR-3)
Create `docs/06-reference/dpop-htu-canonicalization.md`. Move the rule from `04-bff-pattern.md:204–230` into it (keep a one-paragraph summary + link in the BFF doc). Cross-reference from:
- `docs/01-architecture/04-bff-pattern.md`
- The future `apps/lib/api-auth/` (Phase 6b-1) — flag in PLAN.md
- `docs/05-claude-code-prompts/phase-09-hello-world.md`

### C.5 — Write the Istio peer-auth tighten runbook (F-ADR-5)
Create `docs/03-runbooks/istio-peer-auth-tighten.md`. Sections:
1. **Prerequisites** — every workload has a SPIFFE ID; AuthzPolicies cover every legitimate cross-ns call (verify via `kubectl get authorizationpolicy -A` after Section B.2).
2. **Per-namespace dry-run** — `kubectl apply --dry-run=server -f peer-auth-strict.yaml`; expected output.
3. **Staged rollout order** — istio-system first, then platform ns (keycloak, spicedb, openbao), then app ns, then observability.
4. **Verification per stage** — Loki query for AuthorizationPolicy denials; if any, roll back the stage.
5. **Rollback** — `kubectl delete peerauthentication -n <ns> <name>` (PERMISSIVE remains the default elsewhere).

This runbook is what Phase 7c will execute. Mark it as such in the file's header.

### C.6 — Compliance-cutover migration playbook (F-ADR addendum, helps the user's stated goal)
Create `docs/06-reference/migration-keycloak-to-cognito.md`. Cover:
- Realm export from Keycloak (users, clients, groups, roles).
- User-pool creation in Cognito + attribute mapping table.
- Client (BFF) configuration changes — issuer URL, OIDC discovery URL, `kid` derivation (will use `apps/lib/oidc/cognito.go` adapter, not yet written).
- Test plan — confirm OIDC login, refresh, logout work end-to-end against Cognito.
- What stays the same — the BFF code (because of Section A's refactor).

This is a forward-looking doc. It exists to make the operator's "easy compliance transition" promise inspectable.

### C.7 — Commit
```
git add docs/02-decisions docs/01-architecture docs/03-runbooks docs/06-reference CLAUDE.md
git commit -m "fix-after-07: ADRs 0016-0020 + arch doc fixes (F-ADR-1..11)"
```

---

## Section D — PLAN.md, phase prompt navigation, status truth (F-ORD-2..10)

### D.1 — Update PLAN.md status block per the truth table in `00-audit-findings.md`
Open `PLAN.md`. For each phase, ensure the status flag matches the truth table (Section "Status truth table" of the findings doc). Specific edits:

- **Phase 7.0.a** description — update the "6 workloads" reference to "4 OpenBao StatefulSet pods (helloworld-bff and authzen-facade already have startupProbes)." (F-CLU-1 secondary verification)
- **Phase 7.0.b** — investigation is complete (closed during Phase 7 Session 1, 2026-04-30). Replace the "debug" framing with: "Investigation complete; defect is upstream in OpenBao 2.5.3, not Keycloak. Keycloak Evaluate tool confirmed `realm_access.roles[platform_admin]` is present in userinfo, ID token, and access token outputs. OpenBao still reports the claim as missing even with `oidc_scopes` including `roles` and correct `bound_claims` syntax. Root cause is one of: (a) OpenBao not calling userinfo with the right Authorization header to surface scope-gated claims, (b) nested-claim parsing bug for `realm_access/roles`, or (c) userinfo claims not merged into the validation set. Live config uses the `preferred_username` fallback binding (documented in `infrastructure/openbao/configure-auth-oidc.sh`); rebinding to `realm_access.roles` is blocked on upstream OpenBao fix. Track: file/link an upstream issue against `https://github.com/openbao/openbao` before this follow-up can close." Also keep the original ORDERING note for the historical record: "Investigation required Phase 7.4 Loki to be live for verification — confirms F-ORD-3 ordering rule." (F-ORD-3)
- **Phase 7.0.a soak verification** — clarify it's verified at end-of-Phase-7 against the 7.7 platform-health dashboard, not before 7.1. (F-ORD-6)
- **Phase 9 prerequisites** — add Phase 6b-1 ✅, Phase 3 follow-up ✅, "this Fix-after-07 package complete." (F-ORD-2, F-ORD-5)
- **Phase 6b-1** — add a 🟥 BLOCKED marker; under it, list the four open design questions from ADR-0012 lines 76–83 verbatim. State "Phase 6b-1 cannot start until these are resolved." (F-ORD-1)
- **Phase 7b** — add ⚠️ "HOLD until Phase 6b-2 ✅" inline. (F-ORD-4)
- **Phase 3 follow-up** — move scheduling note: "Scheduled to run BEFORE Phase 9. Earliest: after this Fix-after-07 package completes." (F-ORD-5; per operator answer in §0.4)

### D.2 — Add a dependency graph to PLAN.md
Insert this block near the top of PLAN.md (after the table of contents, before "Phase 0"):

```markdown
## Dependency graph (corrected execution order)

(Source: `Fix after 07/00-audit-findings.md` "Dependency graph" section; updated 2026-04-30.)

[paste the ASCII dependency graph from 00-audit-findings.md verbatim]
```

### D.3 — Add phase-navigation header to every phase prompt doc (F-ORD-9)
For each file in `docs/05-claude-code-prompts/phase-*.md`, prepend a header block at the very top (above the existing content):

```markdown
> **Navigation:** [⬅ Previous: Phase X-name](./phase-X-...md) · [➡ Next: Phase Y-name](./phase-Y-...md) · [PLAN.md](../../PLAN.md)
> **Depends on (must be ✅):** Phase A, Phase B
> **Blocks:** Phase C, Phase D
> **Status (PLAN.md authoritative):** ⬜ / 🟡 / ✅
```

The previous/next links follow the **execution order** from §D.2, NOT the alphabetical filename order. Specifically:
- `phase-06-istio-bff` → `phase-06.10b` → `phase-06b-0` → `phase-06b-api-pattern` → `phase-07`
- `phase-07` → `phase-07b` → `phase-07c` → `phase-07d` → `phase-08` → `phase-09`

For phases with multiple "next" options (e.g., Phase 7 leads to 7b, 7c, 7d in any order), list them as `· next options:` separated by `,`.

### D.4 — Reconcile filename sort vs. execution order
Add to `docs/05-claude-code-prompts/README.md`:
```markdown
## Phase filename ordering

Phase prompt filenames do NOT lexically sort to execution order — see PLAN.md
"Dependency graph" for the correct sequence. Each `phase-*.md` has a Navigation
header at the top with prev/next links and dependencies. Filenames preserve
historical phase IDs (06b-0, 06.10b) rather than renumbering for sort order.

To list phases in execution order, see PLAN.md (NOT `ls phase-*.md`).
```

### D.5 — Status block per phase prompt (F-ORD-10)
Below the Navigation header in each phase doc, add a Status block mirroring PLAN.md:
```markdown
> **Status (mirrors PLAN.md):** 🟡 In progress · last updated 2026-04-30
> Source of truth for phase status is PLAN.md; if this conflicts with PLAN.md,
> PLAN.md wins.
```

### D.6 — Commit
```
git add PLAN.md docs/05-claude-code-prompts
git commit -m "fix-after-07: PLAN.md status truth + phase navigation headers (F-ORD-2..10)"
```

---

## Section F — Threat model (F-ADR-13)

> **Why this is in the fix package:** `docs/04-security/README.md` says the threat model should have existed since Phase 1 (or "after Phase 6" per the same README's later guidance — README contradicted itself). It doesn't exist. Six phases of security primitives have been built without a written threat model justifying them. This section creates the initial threat model so Phase 9 apps are designed against documented threats, not retrofitted to controls.
>
> **Operator note:** the user is a senior security developer / cybersecurity specialist. They will have opinions about scope, severity, and accepted residual risk. Show drafts before committing; ask before classifying anything as "accepted residual risk" — that's an explicit risk decision, not a Claude-level call.

### F.1 — Confirm scope before writing
Ask the user:
1. **Trust boundary set** — confirm the boundaries (operator's laptop / browser / `*.secforge.local` ingress / mesh / each platform component / Postgres / OpenBao / external IdP). Defaults are fine but flag any compliance-relevant boundaries the user wants explicit (e.g., "data-at-rest in Postgres" as its own boundary if RLS is the primary tenant separation per ADR-0018).
2. **Threat actor list** — defaults: external unauthenticated attacker, malicious tenant user, compromised app pod, malicious operator with kubectl access, compromised supply chain (image/dep). Confirm or extend.
3. **Out-of-scope assumption** — local-edition specifics (single developer, no multi-tenant ops attacker, Docker Desktop is trusted). State these explicitly so the cloud-edition threat model can supersede later.
4. **Compliance framing** — user said earlier "compliance will come during deployment, not now." Default: do NOT map to FedRAMP/CMMC/NIST controls. Do flag where current decisions help-or-hurt that mapping (one-paragraph appendix). Confirm.

### F.2 — Create `docs/04-security/threat-model.md`
Use the template from `docs/04-security/README.md` lines 17–29 (system diagram, data flows, STRIDE per component, mitigations, residual risks). Structure:

```markdown
# SecForge Local — Threat Model

**Version:** 0.1 · **Date:** YYYY-MM-DD · **Scope:** Local Edition (Docker Desktop K8s)
**Next review:** at Phase 9 (first real apps land), Phase 10 (production-hardening), or any major architecture change.

## 1. System diagram with trust boundaries
[ASCII or mermaid; show: operator browser ↔ ingress ↔ BFF ↔ (Keycloak / Valkey / OpenBao / SpiceDB → AuthZEN-facade / Postgres) with mesh boundary]

## 2. Data flows across boundaries
- Login flow (operator → BFF → Keycloak → BFF → Valkey)
- API call flow (browser → BFF → backend → AuthZEN-facade → SpiceDB)
- Secret-bootstrap flow (BFF → SPIRE workload-API → OpenBao JWT auth → KV read)
- Audit-log flow (component → STDOUT → Promtail → Loki)

## 3. STRIDE per component
For each of: Keycloak, BFF, AuthZEN-facade, SpiceDB, OpenBao, SPIRE, Valkey, Postgres, Istio mesh, Ingress, MinIO, Observability stack, Apps (helloworld-bff, future Phase 9+ apps).

Per component, table:
| Threat | Severity | Mitigation (existing) | Residual risk |
|--------|----------|----------------------|---------------|
| (S) Spoofing — ... | H/M/L | ADR-NNNN, NetworkPolicy X, AuthzPolicy Y | ... |
| (T) Tampering — ... | ... | ... | ... |
| (R) Repudiation — ... | ... | ... | ... |
| (I) Information disclosure — ... | ... | ... | ... |
| (D) Denial of service — ... | ... | ... | ... |
| (E) Elevation of privilege — ... | ... | ... | ... |

## 4. Cross-cutting threats
- Supply chain (image signing — ADR-0004 currently Audit; F-ADR-12 flag)
- Insider / operator with kubectl access (CLAUDE.md "no SA cluster-admin", but human kubectl admins exist)
- Cold-boot Transit token expiry (operator backlog item; runbook hint added)
- Token theft / replay (DPoP-bound — ADR-0011, F-ADR-3)

## 5. Accepted residual risks (require operator sign-off)
- [list — each item has explicit operator confirmation]

## 6. Compliance-mapping note (advisory only)
[one paragraph: where current decisions ease/complicate FedRAMP/CMMC/NIST mapping at deployment]

## 7. Review history
| Date | Reviewer | Changes |
|------|----------|---------|
| YYYY-MM-DD | <user> | Initial version |
```

### F.3 — Coverage requirements
The threat model MUST reference (and the user MUST be able to answer "which row covers this?"):

- All 7 CLAUDE.md "things that should NEVER happen" — each one is a threat the platform mitigates. Cite the row.
- ADRs 0011 (DPoP / single-replica BFF), 0012 (token-exchange NO-GO), 0013 (no env-var secrets), 0014 (api-auth-library), 0015 (secret distribution), 0016 (token lifetimes), 0017 (session expiry), 0018 (RLS), 0019 (secret-distribution interface).
- The four open Phase 6b-1 design questions from ADR-0012 — the threat model should state which threats they affect, even if the answers aren't decided. (This is what makes the design conversation easier.)
- Cold-boot Transit expiry (the runbook fix from 2026-05-01) — captured under (D) Denial of service.

### F.4 — What is NOT in scope of this section
- Detailed threat scenarios for Phase 9+ apps that haven't been built. Add a "Phase 9 update" stub at the bottom: "When the first multi-tenant app lands, add app-specific STRIDE rows."
- FedRAMP/CMMC/NIST 800-53 control mapping. One paragraph in §6 is the cap.
- Penetration-test plan or red-team scenarios. Out of scope; flag as a follow-up if the user asks.

### F.5 — Show before commit
Show the user:
1. The trust-boundary diagram first (gut-check on scope).
2. Then one full STRIDE component (suggest: BFF — most attack surface, exercises every primitive).
3. Then the residual-risks list (this is the part the user must sign off on).

Pause for user feedback at each step. Do not write all 13 components in one go and ask for review at the end — the user is a security specialist; they'll catch scope errors faster on the diagram than buried in row 87.

### F.6 — Commit
```
git add docs/04-security/threat-model.md docs/04-security/README.md
git commit -m "fix-after-07: initial STRIDE threat model (F-ADR-13)"
```

The README already had the contradiction (Phase 1 vs after-Phase-6) fixed before this fix-package was authored — confirm the fix is in `docs/04-security/README.md` line 9 and matches reality.

---

## Section E — Final verification

### E.1 — Build and test
```bash
cd apps/lib && go test ./... && go build ./...
cd ../helloworld-bff && go build ./... && go test ./...
cd ../authzen-facade && go build ./... && go test ./...
```
All must pass. If anything fails, **stop and fix** — do not proceed to merge.

### E.2 — Cluster smoke test
- BFF login walkthrough end-to-end (one user, one session)
- AuthZEN façade `/readyz` (exercises `Evaluate`)
- `kubectl get pods -A` — no CrashLoopBackOff
- `kubectl get authorizationpolicy -A` — every platform ns has a default-deny + at least one explicit ALLOW
- `kubectl get pods -n openbao -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].startupProbe}{"\n"}{end}'` — every OpenBao pod has a startupProbe

Optional but recommended: ask the operator to do a Docker Desktop restart and confirm OpenBao recovers without manual intervention.

### E.3 — Doc verification
- Open `PLAN.md` — confirm dependency graph, status flags, prerequisite lines all match `00-audit-findings.md`.
- Open three random `phase-*.md` files — confirm Navigation header is present and links resolve.
- Open `CLAUDE.md` — confirm passkey row corrected.
- Confirm ADRs 0016, 0017, 0018, 0019, 0020 exist, have `Status:` other than "In progress", and follow the existing ADR style.

### E.4 — Final commit & merge
```
git log --oneline                         # review the four commits
git checkout main                         # or whatever the default branch is
git merge --no-ff fix-after-07           # preserve the branch boundary
```
Tag the merge: `git tag fix-after-07-complete`. Do NOT push to a remote unless the user explicitly asks.

### E.5 — Update PLAN.md with completion line
Add a line under "Phase 7" in PLAN.md:
> **Fix-after-07 package applied 2026-MM-DD.** Findings: see `Fix after 07/00-audit-findings.md`. Diff: `git log fix-after-07-complete`.

---

## Stop conditions

Stop and ask the user before proceeding if:
- Any `go build` or `go test` fails. (Do not bypass.)
- Any AuthzPolicy ALLOW you write would grant something the audit didn't anticipate. (Show the policy and ask.)
- The OpenBao startupProbe socket path you find doesn't match the pattern in §B.1. (Don't guess — investigate.)
- Phase 7 turns out NOT to be ✅ when you start. (See §0.1.)
- The user's answer in §0.4 contradicts something later in this prompt. (Ask which to follow.)
- A finding in `00-audit-findings.md` looks wrong when you go to apply it. (Tell the user; do not silently re-audit.)

## Prompt size

This prompt is intentionally long. Work through it section by section: A → B → C → D → E. Update TodoWrite as you complete each section. **Don't try to batch sections** — each section's work depends on the previous one being verifiably done.

## End

When complete, tell the user:
1. Number of files changed.
2. Number of ADRs added.
3. Number of AuthzPolicies added (and which namespaces).
4. Whether the OpenBao restart issue is resolved.
5. Anything in `00-audit-findings.md` you did NOT fix and why (e.g., F-ORD-1 needs operator design conversation; F-ADR-12 needs operator key-custody decision).
6. The two follow-ups this package opened: (a) Phase 6b-1 design conversation, (b) ADR-0020 companion runbook.
