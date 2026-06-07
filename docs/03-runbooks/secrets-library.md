# `apps/lib/secrets/` — operator runbook

> **Source of truth:** [ADR-0013 — outbound secrets pattern](../02-decisions/0013-outbound-secrets-no-env.md)
> **Library code:** `apps/lib/secrets/`
> **Reference adopter:** `apps/security-events-collector/` (a live Go consumer of `apps/lib/secrets`)

This runbook is the operator-facing guide to the outbound-secrets library
that ships with Phase 6b-2. If you're an SecForge developer reaching for
an `.env` file: **stop and read this instead.** The cluster has six
guardrail layers that will reject what you're about to do; the fix is the
same in every case.

## When to use this library

- Your app needs a third-party API credential (Stripe, OpenAI, SendGrid,
  GitHub, SAM.gov, etc.) at runtime.
- Your app needs a database password that should rotate per-pod (i.e.,
  not be baked into a K8s Secret at provision time).

If you're bootstrapping a `private_key_jwt` PEM at startup (BFF-shape),
you're already on the *bootstrapper* side of the same package — see
`SecretBootstrapper` in `bootstrapper.go` and its construction in
`apps/security-events-collector/main.go`.

## When NOT to use this library

- Operator-shaped consumers that read K8s `Secret` resources directly
  (e.g., AuthZEN façade, the SpiceDB chart). Those stay VSO-rendered per
  ADR-0015. The split is intentional; do not migrate operator-shaped
  consumers without an explicit ADR amendment.
- Bootstrap credentials sourced before the first OpenBao auth call. Use
  `SecretBootstrapper` (the lower-level interface) for those.

## Static credential — happy path

```go
import libSecrets "github.com/secforge/lib/secrets"

// Once at startup, sharing the SecretBootstrapper instance with the
// rest of the app's startup chain.
client, err := libSecrets.New(bootstrap, libSecrets.Config{
    AppName:  "<this-app>",         // matches SPIFFE-ID short name
    CacheTTL: 5 * time.Minute,
    Hardened: true,                 // default for new apps
})
if err != nil { return err }
```

Then at the call site:

```go
secret, err := client.GetField(ctx, "stripe", "api_key")
if err != nil { return err }

err = secret.Use(func(b []byte) error {
    return callStripe(string(b))
})
// Secret is best-effort-zeroed inside Use.
```

`secret` is a `libSecrets.Secret` — its `String()` returns
`"[redacted]"`, its `MarshalJSON()` returns `"[redacted]"`. Accidentally
`fmt.Printf`-ing it or letting it land in a structured log won't leak
the value.

## Dynamic credential (database password)

```go
creds, err := client.GetDynamic(ctx, "readonly")
if err != nil { return err }

dsn := creds.DSN("postgres://{{.Username}}:{{.Password}}@db:5432/x?sslmode=verify-full")
db, err := sql.Open("pgx", dsn)
```

`DynamicCredential` exposes Username/Password as bare strings — they
flow straight into the DSN, so a `Secret`-wrapper would force every
consumer through `Use` just to assemble the string. Redaction is at
the logging boundary instead (`String()` and `MarshalJSON()`).

`creds.LeaseDuration` is the credential's hard expiry. The library does
not auto-revoke — callers should arrange teardown when the lease ends.
Explicit revocation lands when the first dynamic-cred consumer arrives
in Phase 9+ (and the `SecretBootstrapper` interface gains a Post helper).

## Bundled accessor helpers

Per ADR-0013 § 7, the Secret type ships three idiomatic helpers so common
consumption patterns don't reach into the raw byte slice:

```go
// HTTP header (e.g., "Authorization: Bearer <secret>")
name, value, _ := secret.HTTPHeader("Bearer")
req.Header.Set(name, value)

// HTTP basic auth
name, value, _ := secret.BasicAuth("alice")
req.Header.Set(name, value)

// Database DSN template
dsn, _ := secret.DSN("postgres://%s@db:5432/x?password=%s&sslmode=verify-full")
```

Each helper invokes `Use` internally, so the same zeroing semantics apply.

## Common mistakes

| Mistake | Why it's caught | Where it's caught |
|---|---|---|
| Putting the secret back into an env var "for convenience" | Kyverno `no-secret-shaped-env-vars` | Layer 4 — admission |
| `fmt.Errorf("call failed: %s", secret)` | `Secret.String()` returns `[redacted]` | Layer 5 — runtime |
| `slog.Info("got secret", "value", secret)` | Same — `Secret.MarshalJSON()` | Layer 5 — runtime |
| Capturing the secret in a goroutine that outlives the request | Same; the value is `[redacted]` everywhere `Secret` lands | Layer 5 — runtime |
| Sending it to Sentry via panic context | `apps/lib/errreport/` `ScrubbingReporter` redacts the panic message before reaching the sink | Layer 6 — error reporting |

## Adding a new third-party integration

1. Decide the integration name (e.g., `stripe`, `openai`). Convention: lowercase, vendor-canonical.
2. Pre-populate OpenBao at the canonical path:
   ```bash
   bao kv put secret/apps/<this-app>/<integration> api_key=<value>
   ```
   (Operator-time. Per ADR-0013 § 4 the templated policy authorizes
   reads from `secret/data/apps/<this-app>/*`.)
3. Use `client.GetField(ctx, "<integration>", "<field>")` in code.
4. Add a test that exercises the call site — the standard pattern is a
   `fakeBootstrapper` returning a canned KV-v2 envelope; see
   `apps/security-events-collector/bootstrap_test.go`.
5. Document the integration's rotation cadence in your app's README.
   ADR-0013 mandates rotation MUST be possible without redeploying any
   app — the library's TTL cache will pick up a fresh value automatically.

## Rotation flow

The library does NOT trigger rotations. Operators rotate values in
OpenBao directly:

```bash
bao kv put secret/apps/<this-app>/<integration> api_key=<new-value>
```

The next `GetField` call AFTER `CacheTTL` expires will fetch the new
value. `CacheTTL` defaults to 5 minutes; tune via `Config.CacheTTL` if
your integration's rotation cadence requires faster pickup.

## Hardened mode rollout

Per ADR-0013 § 7, `Hardened: true` is the default for **new** apps. The
non-Hardened path exists solely for transitional onboarding of existing
apps; today no app uses it. Before the AWS migration the default flips
permanently; the non-Hardened code path is removed in a single
subsequent commit.

If your app needs `Hardened: false` for any reason, file an ADR
amendment first — the bypass should be deliberate, time-bounded, and
visible.

## Related

- [secrets-guardrails-monitoring.md](./secrets-guardrails-monitoring.md) — event schema + Phase 7b wire-up
- [secrets-guardrails-verification.md](./secrets-guardrails-verification.md) — the 8-script verify suite
- [migrate-env-to-openbao.md](./migrate-env-to-openbao.md) — converting an existing `.env`-driven app
- [new-app-bootstrap.md](./new-app-bootstrap.md) — the cp-and-init pattern for new apps
- [ADR-0013](../02-decisions/0013-outbound-secrets-no-env.md) — the policy this library enforces
- [ADR-0019](../02-decisions/0019-secret-distribution-interface.md) — the SecretBootstrapper interface
