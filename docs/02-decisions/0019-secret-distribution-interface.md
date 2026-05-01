# ADR-0019: Secret distribution interface for first-class apps (`SecretBootstrapper`)

**Status**: Accepted
**Date**: 2026-05-01
**Decision-makers**: Project owner

## Context

[ADR-0015](./0015-secret-distribution-pattern.md) established the asymmetric VSO-vs-direct-API split: workloads we don't control end-to-end (SpiceDB-via-operator, AuthZEN-façade) consume secrets via Vault Secrets Operator rendering K8s Secrets; first-class apps whose code path we own (BFF, future Phase 9/10 apps) read directly from OpenBao via a shared library at `apps/lib/secrets/`.

ADR-0015 referenced `apps/lib/secrets/` as the home of the direct-API path but did not define the interface. The first-class apps had nothing to consume; the BFF was reaching into OpenBao via hand-rolled HTTP at `apps/helloworld-bff/openbao.go`.

Fix-after-07 §A.3 created `apps/lib/secrets/` with the `SecretBootstrapper` interface (and migrated the BFF to use it). This ADR formalizes that interface as the contract every future first-class app implements against, and what a future non-OpenBao adapter looks like.

## Decision

The `SecretBootstrapper` interface (live at `apps/lib/secrets/bootstrapper.go`) is the canonical contract for first-class app secret bootstrap:

```go
type SecretBootstrapper interface {
    GetClientKey(ctx context.Context) ([]byte, error)
    GetKV(ctx context.Context, path string) ([]byte, error)
}
```

Implementations are constructed via adapter-specific factory functions. The OpenBao adapter (today's only implementation):

```go
func NewOpenBaoBootstrapper(addr, jwtPath, role, clientKVPath string) (SecretBootstrapper, error)
```

### What `GetClientKey` does

Returns the per-app `private_key_jwt` PEM bytes from the KV path the constructor was configured with. This is the BFF's bootstrap-at-startup pattern: SPIRE writes a JWT-SVID to disk; the lib exchanges it via OpenBao's `auth/jwt/login` for a short-lived client token; the lib reads the configured KV path and returns the `private_pem` field's value.

### What `GetKV` does

Returns the raw KV-v2 response body for any path the bound role's policy permits. Apps that need to read additional secrets (Phase 9+ apps with multiple `keycloak/clients/<id>` entries; Phase 10 apps with per-tenant config) use this. It does NOT expose login mechanics — the lib auths each call internally.

### What this interface explicitly does NOT do

- **Outbound third-party API key fetch** (Stripe, OpenAI, SendGrid, etc.). Phase 6b-2 extends this package with a Hardened-mode wrapper, refresh helpers, and a `Use(func([]byte))` accessor pattern designed for repeated calls during request handling. ADR-0013 (no `.env`) is the authoritative ADR for that scope; this ADR is for STARTUP / LONG-LIVED-CACHE bootstrap of per-app credentials.
- **Token caching across calls**. `GetClientKey` and `GetKV` re-login per call. Apps that need many reads should batch or wrap with caller-side caching. The OpenBao adapter's per-call login is cheap (a single HTTP roundtrip + a KV read) and the lifetime mismatch between the 1 h client token and the millisecond-scale call duration makes caching not worth the bug surface.
- **Secret loading from env vars or files**. The library NEVER reads `os.Getenv` or `os.ReadFile` for secret material. Apps load config (paths, addresses, role names) from env and pass already-loaded values into `New*Bootstrapper`. This invariant exists so the library's surface is testable without environment manipulation and so a misconfigured app fails at the call site, not at the env-var read.

## Required behavior of any implementation

The interface contract enforces three invariants that adapters MUST honor:

1. **Errors include the path or operation but never the secret value.** Test coverage MUST include the "no leak" assertion (see `apps/lib/secrets/openbao_test.go::TestGetClientKey_NoSecretValueInError`).
2. **Per-call independence.** No package-level state. Each call carries its own context, builds its own auth, and returns when complete. A failing call MUST NOT corrupt subsequent calls.
3. **Constructor validates required arguments.** Empty or nil critical fields fail at construction, not at first call. The OpenBao adapter checks `addr`, `jwtPath`, `role`, and `clientKVPath` for non-empty strings.

## Future adapters

The interface is designed to accommodate at least these alternatives without changing apps:

### `NewAWSSecretsManagerBootstrapper(region string, kmsArn string, roleArn string, clientSecretArn string)`

`GetClientKey`: AssumeRole via IRSA / IAM Roles for Service Accounts → `secretsmanager:GetSecretValue` against the configured ARN → unmarshal the JSON body → return the `private_pem` field. `GetKV`: `secretsmanager:GetSecretValue` against an arbitrary path-shaped ARN. Compliance-cutover migrations that move the platform from OpenBao to AWS-native secret management land this adapter; apps don't change.

### `NewVaultEnterpriseBootstrapper(addr string, namespace string, ...)`

Identical surface to OpenBao adapter (OpenBao is a Vault fork; the API is compatible). The adapter exists primarily to namespace-scope reads in Vault Enterprise's multi-namespace model.

### `NewGCPSecretManagerBootstrapper(projectID string, audience string, secretName string)`

Workload Identity Federation against GCP IAM, then `secretmanager.googleapis.com:access` against the configured secret. Mirrors the AWS adapter shape.

These adapters DO NOT exist today. This ADR documents that the SecretBootstrapper interface is the right shape FOR them — the proof is that the AWS / Vault Enterprise / GCP variants all map cleanly onto `GetClientKey` / `GetKV` without leaking provider-specific concepts.

## Why this interface, not a wider one

Two functions is the minimum that supports both the BFF's bootstrap pattern (a configured-path read) and the more general "read any path the role permits" pattern apps may need. Wider interfaces considered and rejected:

- **`GetClientKey() / GetKV() / GetDynamic()`** for dynamic database creds. Phase 6b-2 adds this on a separate type (`DynamicCredential` with `Revoke()` lease management); folding it into `SecretBootstrapper` would force every adapter to implement lease lifecycle even if their backend doesn't have leases (AWS Secrets Manager doesn't).
- **`Bootstrap() ([]byte, error)`** as a single zero-arg method. Too narrow: when a Phase 9+ app needs both its private_key_jwt AND its database password, the constructor would have to take both paths. `GetKV(path)` keeps the constructor narrow.
- **`io.Reader`-shaped streaming**. Secrets are small (bytes to kilobytes); streaming complicates the redaction discipline (every reader-write boundary is a new place to leak).

## Cross-references

- [ADR-0013](./0013-outbound-secrets-no-env.md) — no env-var secrets (the policy this interface implements one half of)
- [ADR-0015](./0015-secret-distribution-pattern.md) — VSO vs direct-API split (this interface IS the direct-API path)
- [`apps/lib/secrets/bootstrapper.go`](../../apps/lib/secrets/bootstrapper.go) — interface declaration
- [`apps/lib/secrets/openbao.go`](../../apps/lib/secrets/openbao.go) — OpenBao adapter
- [`apps/lib/secrets/openbao_test.go`](../../apps/lib/secrets/openbao_test.go) — contract test suite
- [Fix after 07 § F-ADR-10](../../Fix%20after%2007/00-audit-findings.md#f-adr-10--medium--missing-adr--secret-distribution-interface-for-first-class-apps) — the audit finding this ADR closes

## Re-evaluation triggers

- A new app's secret-loading needs an operation neither `GetClientKey` nor `GetKV` cleanly serves → propose a third method here, OR write a sibling type. Do NOT bolt on a method that returns an adapter-specific concept (lease ID, ARN, tag) via the interface.
- Phase 6b-2 extends `apps/lib/secrets/` with the Hardened-mode `Secret` type + `Use()` accessor pattern → that's an additive layer, not a change to this interface. Confirm.
- A future adapter for a backend whose surface CAN'T cleanly implement `GetKV(path)` (e.g., a backend that doesn't expose paths) — supersede with a different abstraction. Better to admit the change than warp this interface.
