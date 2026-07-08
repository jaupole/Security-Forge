# New SecForge app — bootstrap procedure

> **Source of truth:** [`templates/app-repo/`](../../templates/app-repo/) +
> [ADR-0013](../02-decisions/0013-outbound-secrets-no-env.md).
> **Related:** [secrets-library.md](./secrets-library.md), [ci-secrets-check.md](./ci-secrets-check.md).

This runbook is the cp-and-init pattern for spinning up a new
SecForge first-class app. Apply it BEFORE writing any application code
so the guardrail layers are in place from commit 1.

## What you get

When you finish this runbook, the new app repo has:

- A secret-hostile `.gitignore` (bans `.env*`, `*.pem`, `*.key`, etc.)
- An `.env.example` placeholder for non-secret config only
- Pre-commit hooks: gitleaks, hadolint, plus two SecForge-specific local
  hooks (`block-env-files`, `block-secret-shaped-vars`)
- A `.dockerignore` mirroring the secret-hostile patterns
- A canonical multi-stage `Dockerfile.example`
- A `README-secrets.md` documenting the no-`.env` rule for new
  contributors
- A GitHub Actions `secrets-check.yml` workflow that mirrors every
  pre-commit hook (so `git commit --no-verify` cannot bypass)
- A `.template-version` file that lets Phase 7's drift-detection cron
  know whether the app is up to date with the platform's templates

## Prerequisites

Operator-time, before running any of the steps below:

- [ ] Decide the app's canonical short name (matches SPIFFE-ID, OpenBao
      role, ServiceAccount). Convention: lowercase-kebab.
- [ ] Confirm the app's namespace exists. New first-class apps go into
      `app` ns by default; multi-tenant apps may want a dedicated ns
      (file an ADR if so).
- [ ] Confirm the namespace-scoped ClusterSPIFFEID covering the app's
      ns is in place (Phase 2's coverage already includes `app`).
- [ ] Allocate a Keycloak client ID + audience for the app's API
      surface (Phase 6b-1 pattern).

## Step 1 — Copy the templates

```bash
APP_NAME=<short-name>
APP_DIR=<absolute-path-to-new-repo>

cp -r templates/app-repo/.gitignore "$APP_DIR/"
cp -r templates/app-repo/.env.example "$APP_DIR/"
cp -r templates/app-repo/.pre-commit-config.yaml "$APP_DIR/"
cp -r templates/app-repo/.dockerignore "$APP_DIR/"
cp -r templates/app-repo/Dockerfile.example "$APP_DIR/Dockerfile"
cp -r templates/app-repo/README-secrets.md "$APP_DIR/"
cp -r templates/app-repo/.template-version "$APP_DIR/"
cp -r templates/app-repo/.gitleaks.toml "$APP_DIR/"
mkdir -p "$APP_DIR/.github/workflows"
cp templates/app-repo/.github/workflows/secrets-check.yml \
   "$APP_DIR/.github/workflows/"
```

## Step 2 — Install pre-commit hooks

```bash
cd "$APP_DIR"
git init
pre-commit install
pre-commit run --all-files
```

Expected: every hook passes against the placeholder template content.
If gitleaks flags anything, the template was modified in flight — see
the [`templates/app-repo/`](../../templates/app-repo/) source of truth.

## Step 3 — Wire OpenBao access

The app needs:

1. A SPIFFE-ID issued by the namespace ClusterSPIFFEID. Convention:
   `spiffe://secforge.platform/ns/<ns>/sa/<app-name>`.
2. An OpenBao JWT-auth role bound to that SPIFFE-ID with a per-app policy
   under `platform/manifests/openbao/policies/` (model it on the existing
   per-app policies there; app VSO roles are wired via `05j-app-vso-roles.sh`).
3. The policy authorizes reads from `secret/data/apps/<app-name>/*`
   automatically via the SPIFFE-ID's `metadata.app` attribute.

For step 1+2, mirror the per-app onboarding in
`platform/components/05c-openbao-configure.sh` + `05j-app-vso-roles.sh`.
Step 3 is automatic once 1+2 are in place.

Verify:

```bash
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
    bao read auth/jwt/role/<app-name>
```

## Step 4 — Adopt the secrets library

In your app's Go module:

```go
import libSecrets "github.com/secforge/lib/secrets"

bootstrap, err := libSecrets.NewOpenBaoBootstrapper(
    "https://openbao.openbao.svc.cluster.local:8200",
    "/shared/openbao.jwt",   // path the spiffe-helper init wrote to
    "<app-name>",            // role name
    "secret/data/keycloak/clients/<app-name>",  // bootstrap KV path
)
if err != nil { /* ... */ }

// And for outbound credentials:
client, err := libSecrets.New(bootstrap, libSecrets.Config{
    AppName:  "<app-name>",
    CacheTTL: 5 * time.Minute,
    Hardened: true,
})
```

See [secrets-library.md](./secrets-library.md) for the full call-site
pattern.

## Step 5 — Adopt the API-auth library (if the app accepts inbound traffic)

Adopt the `apps/lib/api-auth/` library (see its `client.go` + tests for the
integration shape); ADR-0014 documents the design.

## Step 6 — Wire the error reporter

```go
import "github.com/secforge/lib/errreport"

reporter := &errreport.ScrubbingReporter{
    Scrubber: errreport.NewDefaultScrubber(),
    Sink:     errreport.NewNoOpSink(),
}
```

Use `reporter.Capture(ctx, err, tags)` at every error-emission site that
would otherwise reach Sentry/Rollbar/OTel error events. Phase 7 swaps
the Sink for the production reporter; you change zero lines.

See `apps/lib/errreport/` and its live consumer `apps/security-events-collector/`
for the singleton pattern.

## Step 7 — Adopt the deployment pattern

Mirror the deployment scaffold in [`templates/app-repo/`](../../templates/app-repo/) (live example: `apps/security-events-collector/deploy/`):

1. ServiceAccount with `spiffe.io/spire-managed-identity: "true"` label
2. Deployment with the spiffe-helper init container writing JWT-SVID to
   a shared emptyDir
3. Service exposing the app's port
4. NetworkPolicy: default-deny + selective allow (DNS, OpenBao,
   Keycloak/Ingress, downstream APIs as needed)
5. ServiceMonitor if the app exposes Prometheus metrics

## Step 8 — Adopt the build pattern

Copy `apps/security-events-collector/build.sh` (or `templates/app-repo/Dockerfile.example`) and adjust:

- Image name + version
- Build context (one level above the app's go.mod when using the
  `replace github.com/secforge/lib => ../lib` pattern)

The Trivy invocation MUST include `--scanners vuln,secret` per
ADR-0013 § Layer 3 (commit 3 flipped this; new apps inherit it via this
runbook).

## Step 9 — Configure CI branch protection

See [ci-secrets-check.md](./ci-secrets-check.md) for the GitHub-side
setup that makes `secrets-check.yml` a required check on the default
branch.

## Step 10 — Verify

Run the full guardrail suite against the new app:

```bash
# Guardrails are now Kyverno-enforced (no-secret-shaped-env-vars, legacy-secret-env-expiry,
# etc.) with a self-test at platform/manifests/kyverno/07-guardrail-selftest.yaml.
# See secrets-guardrails-verification.md.
```

Expected: all 9 scripts PASS.

## Data plane (DB / RLS / canonical core)

If the app has a database, use the [`templates/app-repo/db/`](../../templates/app-repo/db/)
starter — it encodes the fleet DB decisions so the app is conformant on day one (ADRs
[0029](../02-decisions/0029-per-app-database-strategy.md)/[0041](../02-decisions/0041-canonical-core-data-spine.md)/[0042](../02-decisions/0042-rls-guc-standard-app-org-id.md)/[0043](../02-decisions/0043-ecosystem-db-shared-package.md)/[0044](../02-decisions/0044-physical-db-consolidation.md)).

- [ ] Adopt `@jaupole/ecosystem-db`'s `/migrate` runner (thin `src/db/migrate.ts` wrapper).
- [ ] Every org-scoped table gets the `db/rls-template.sql` shape (FORCE RLS, `app.org_id` GUC).
- [ ] Apply `db/core-projections.sql`; wire `db/core-sync.stub.ts` (reference: PM's
      `src/lib/core-sync.ts`); register the app as a `core-export` consumer with Control.
- [ ] Fill `db/conformance-manifest.json`; add `db/harness-ci.snippet.yml` to the build workflow.
- [ ] **Operator**: add the database to the consolidated cluster — see
      [ecosystem-db-operations.md](./ecosystem-db-operations.md) §"Add a database for a new app"
      (create DB + role, `allow-ingress-from-apps` netpol, app-side egress netpol, point
      `DATABASE_URL` at `ecosystem-db-rw`; make the app's `<app>-ecodb` secret OpenBao-backed +
      VSO-rendered per ADR-0044).

## Operator-time prerequisites that aren't in the templates

The templates cover the developer-facing layers. Before the app can be
deployed in-cluster, the operator also needs to:

- [ ] Provision the Keycloak client (`kcadm-admin` per ADR-0022)
- [ ] Pre-populate any required OpenBao KV paths
- [ ] Apply the K8s manifests (`kubectl apply -f apps/<app>/deploy/`)
- [ ] Confirm the SPIFFE-ID is being issued
  (`kubectl exec -n spire-server spire-server-0 -- /opt/spire/bin/spire-server entry show`)

## Related

- [secrets-library.md](./secrets-library.md) — library API
- [ci-secrets-check.md](./ci-secrets-check.md) — CI branch protection
- [secrets-guardrails-verification.md](./secrets-guardrails-verification.md) — verify suite
- [migrate-env-to-openbao.md](./migrate-env-to-openbao.md) — for apps coming from a `.env` past
- [`templates/app-repo/`](../../templates/app-repo/) — the templates themselves
- [`templates/app-repo/db/`](../../templates/app-repo/db/) — the DB / RLS / canonical-core starter
- [ecosystem-db-operations.md](./ecosystem-db-operations.md) — the consolidated DB cluster (ADR-0044)
