# Migrate `.env`-driven app → OpenBao + `apps/lib/secrets/`

> **Source of truth:** [ADR-0013](../02-decisions/0013-outbound-secrets-no-env.md)
> **Library:** [`apps/lib/secrets/`](../../apps/lib/secrets/) (see [secrets-library.md](./secrets-library.md))

This runbook is the step-by-step for converting an existing `.env`-driven
project to the SecForge outbound-secrets pattern. **No app uses `.env`
in this repo today** — Phase 6b-2 was a clean break, not a migration. But
Phase 9/10 will onboard apps that arrive with `.env` in their git
history; this runbook is for that work.

## Pre-migration checklist

Before touching code:

- [ ] **Inventory every secret.** Walk the existing `.env` and `.env.*`
      files; list every key with a real (or possibly-real) credential.
- [ ] **Audit git history.** `git log -p -- .env .env.*` will surface
      every value that was ever committed, even if subsequently deleted.
      A value that lived in any branch's history must be considered
      compromised.
- [ ] **Rotate every credential whose value appears in git history.**
      This is non-negotiable. The migration moves the *new* values to
      OpenBao; the *old* values must be revoked at the vendor side.
- [ ] **Confirm OpenBao access.** The target app has a SPIFFE-ID, a
      bound JWT-auth role, and the templated policy authorizes reads
      from `secret/data/apps/<app>/*`. See Phase 5 if any of those is
      missing.

## Step 1 — Move secret values into OpenBao

For each integration:

```bash
bao kv put secret/apps/<app>/<integration> \
    api_key=<rotated-value> \
    api_secret=<rotated-value>
```

Group related fields under one integration path. Common groupings:

```
secret/apps/<app>/stripe          { api_key, webhook_secret }
secret/apps/<app>/openai          { api_key, organization_id }
secret/apps/<app>/sendgrid        { api_key, from_email }
secret/apps/<app>/github          { app_id, client_secret, webhook_secret }
```

Confirm each integration with a read-back:

```bash
bao kv get -format=json secret/apps/<app>/<integration>
```

## Step 2 — Wire the library at startup

Add the outbound-secrets Client construction to your app's `main.go`,
after the bootstrapper is in scope:

```go
client, err := libSecrets.New(bootstrap, libSecrets.Config{
    AppName:  "<app>",
    CacheTTL: 5 * time.Minute,
    Hardened: true,
})
if err != nil {
    log.Error("outbound secrets client init failed", "err", err)
    os.Exit(1)
}
```

(`bootstrap` is the existing `SecretBootstrapper` your BFF or service
already uses — typically constructed by `NewOpenBaoBootstrapper(...)`.)

Reference: `apps/security-events-collector/main.go` (a live `SecretBootstrapper` consumer).

## Step 3 — Swap each call site

For every place the app currently reads `os.Getenv("STRIPE_API_KEY")`:

```go
// BEFORE
key := os.Getenv("STRIPE_API_KEY")
err := stripe.Authenticate(key)

// AFTER
secret, err := client.GetField(ctx, "stripe", "api_key")
if err != nil { return err }
err = secret.Use(func(b []byte) error {
    return stripe.Authenticate(string(b))
})
```

If the vendor SDK demands a string and offers no `[]byte` constructor,
convert inside `Use`. The Secret zeros itself when `Use` returns; the
intermediate `string` allocates a new copy, which is acceptable for a
one-shot consumption but should NOT be stashed in a long-lived variable.

## Step 4 — Delete `.env` files from the repo and from history

```bash
git rm .env .env.example  # if .env.example contained real values
git commit -m "remove .env (migrated to OpenBao per ADR-0013)"
```

If git history contains values that were rotated in Step 1, the rotation
is sufficient — the old values are now invalid at the vendor. **Do not**
attempt to rewrite git history (BFG / `git filter-repo`) unless the
threat model specifically requires it; rewriting history breaks every
existing checkout and is a high-blast-radius operation.

## Step 5 — Adopt the templates

```bash
cp -r templates/app-repo/.gitignore <app-dir>/.gitignore
cp -r templates/app-repo/.dockerignore <app-dir>/.dockerignore
cp -r templates/app-repo/.pre-commit-config.yaml <app-dir>/.pre-commit-config.yaml
cp -r templates/app-repo/.gitleaks.toml <app-dir>/.gitleaks.toml
cp -r templates/app-repo/.template-version <app-dir>/.template-version
mkdir -p <app-dir>/.github/workflows
cp templates/app-repo/.github/workflows/secrets-check.yml <app-dir>/.github/workflows/
```

See [new-app-bootstrap.md](./new-app-bootstrap.md) for the full pattern
including pre-commit install + branch-protection setup.

## Step 6 — Verify

```bash
# Guardrails are now Kyverno-enforced; self-test at
# platform/manifests/kyverno/07-guardrail-selftest.yaml. See secrets-guardrails-verification.md.
```

Expected: all 9 scripts PASS. Any FAIL means a guardrail layer
regressed during the migration; see
[secrets-guardrails-verification.md](./secrets-guardrails-verification.md).

## Common pitfalls during migration

| Symptom | Likely cause |
|---|---|
| Pod admission denied with `ADR-0013 violation — env name matches secret-shaped regex` | An old `env:` block still contains `KEY`/`SECRET`/`TOKEN`/`PASSWORD`/`CREDENTIAL` — remove it; the value comes from OpenBao now. |
| Pre-commit blocks the migration commit on `.env` | Stash `.env` first, then `pre-commit run --all-files`, then delete `.env` in a separate commit. |
| `client.GetField` returns "field not present at integration=..." | The KV path doesn't have that field. Re-run `bao kv get` to confirm. Field names are exact-match; `api_key` ≠ `apiKey`. |
| Vendor SDK demands a specific env var name (e.g. `STRIPE_API_KEY`) | Use the time-bounded escape hatch (ADR-0013 § 8). Add the annotation pair to the Pod spec and file a removal ticket. |

## Related

- [secrets-library.md](./secrets-library.md) — library API reference
- [new-app-bootstrap.md](./new-app-bootstrap.md) — for new apps starting fresh
- [secrets-guardrails-verification.md](./secrets-guardrails-verification.md) — verify suite usage
- [ADR-0013](../02-decisions/0013-outbound-secrets-no-env.md) — the policy
