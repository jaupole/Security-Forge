# README — Outbound Secrets

> **If you're about to add an API key, password, or token to this repo: STOP.**
> Read this first. This page exists because pre-commit, CI, Trivy, Kyverno,
> and the `apps/lib/secrets/` library will all reject what you're about to
> do, and the fix is the same in every case.

## TL;DR

Outbound third-party credentials (Stripe, OpenAI, SendGrid, SAM.gov,
GitHub, etc.) live in **OpenBao** at `secret/data/apps/<this-app>/<integration>`.
At runtime, this app fetches them via SPIFFE-JWT auth using `apps/lib/secrets/`.
There is no `.env`, no env-var-as-secret, no K8s `Secret` mounted as a file,
no value baked into the image. Every layer of the platform enforces this.

For the policy rationale and the full guardrail design, see
[ADR-0013 — Outbound secrets pattern: no .env, no exceptions](https://github.com/secforge/platform/blob/main/docs/02-decisions/0013-outbound-secrets-no-env.md).

## What you should do instead

### 1. Static credential (Stripe API key, OpenAI API key, SendGrid token)

Store it once in OpenBao at `secret/data/apps/<app>/<integration>`:

```bash
bao kv put secret/apps/<app>/<integration> api_key="<value>"
```

(Operator-time only. The app's `private_key_jwt` for OpenBao auth is
provisioned at app-onboarding time per the new-app-bootstrap runbook.)

In Go, fetch and use:

```go
import "secforge.local/apps/lib/secrets"

client, err := secrets.New(ctx, secrets.Config{
    App:      "<this-app>",
    Hardened: true,
})
if err != nil { return err }

stripeKey, err := client.GetField(ctx, "stripe", "api_key")
if err != nil { return err }
defer stripeKey.Zero()

err = stripeKey.Use(func(b []byte) error {
    return callStripe(string(b))
})
```

`stripeKey` is a `secrets.Secret`, NOT a `string`. Its `String()` and
`MarshalJSON()` return `[REDACTED]`, so accidentally `fmt.Printf`-ing it
or letting it land in a Sentry context dictionary won't leak the value.

### 2. Dynamic credential (database password rotated per-pod)

Use `Client.GetDynamic`:

```go
creds, err := client.GetDynamic(ctx, "database", "<this-app>-readonly")
if err != nil { return err }
defer creds.Zero()
// creds.Use(...) hands you a fresh, short-lived DB credential.
```

OpenBao mints the credential at request time and revokes it when its
lease expires. Nothing is ever written to a Secret resource, an env
var, or a file.

### 3. The escape hatch for vendor SDKs that demand a specific env var

Some vendor SDKs (rare) hard-require a credential to arrive via a
specific env var name (e.g., `STRIPE_API_KEY`). For these, and only
these, an **expiring** escape hatch exists. The Pod adds two
annotations:

```yaml
metadata:
  annotations:
    secforge.local/legacy-secret-env: "JIRA-1234"           # ticket ref
    secforge.local/legacy-secret-env-expires: "2026-07-30"  # ≤ 90d out
```

Without both annotations, the Kyverno `no-secret-shaped-env-vars`
ClusterPolicy rejects the Pod at admission. The escape hatch is a
**tracked debt with a hard deadline**, not a permanent home for any
credential. See ADR-0013 § Self-expiring escape hatch.

## What you should NEVER do

- ❌ Put a secret in `.env` (any `.env*` file blocks at pre-commit + CI).
- ❌ Put a secret in `.env.example` (the file is for non-secret config shape).
- ❌ `os.Getenv("STRIPE_API_KEY")` — pre-commit `block-secret-shaped-vars`
  fails the commit; Kyverno rejects the Pod even if you `--no-verify`.
- ❌ `kubectl create secret generic ...` mounted as an env var or file
  for an outbound credential. K8s Secrets are base64, not encrypted at
  rest, and any pod with `secrets:get` in its namespace can read them.
- ❌ Bake a credential into the image (`COPY .env`, hard-coded constant,
  layered tarball). Trivy `--scanners secret` fails the build.
- ❌ `git commit --no-verify` to skip pre-commit. CI re-runs every check
  and blocks the merge.

## When you need help

- For an integration that doesn't fit `GetField` or `GetDynamic` cleanly:
  read ADR-0013 § Re-evaluation triggers, then propose the addition in
  PR review on the platform repo. Do NOT add a method that returns
  adapter-specific concepts (lease ID, ARN, tag) to the public Client.
- For a vendor SDK that hard-requires an env var: use the escape hatch
  with a real ticket and a real deadline.
- If the pre-commit hook fires on a legitimate non-secret env var name
  (e.g. `TOKEN_BUCKET_SIZE`): rename the var. The hook is intentionally
  blunt — false positives are cheaper than a leaked secret.
