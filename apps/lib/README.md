# apps/lib — shared libraries for first-class SecForge apps

This directory holds vendor-agnostic interfaces wrapping security backends
(OIDC IdP, secret store, authorization engine). Apps under `apps/*` import
from here so a future backend swap (Keycloak → Cognito, OpenBao → AWS Secrets
Manager, SpiceDB → Cedar) does not require app code rewrites.

| Package    | Interface             | Current adapter | ADR                                                  |
|------------|-----------------------|-----------------|------------------------------------------------------|
| `oidc`     | `Provider`            | Keycloak        | (Phase 6 design + Fix-after-07 §A.2)                 |
| `secrets`  | `SecretBootstrapper`  | OpenBao         | [ADR-0019](../../docs/02-decisions/0019-secret-distribution-interface.md) |
| `authzn`   | `AuthZN`              | SpiceDB         | (Phase 4 + Fix-after-07 §A.4)                        |

Adapter selection is by factory function — see each subpackage for its
constructor signature. Apps read env vars / OpenBao secrets and pass values
in to the constructor; this library does not load its own config.

## Module layout

Single Go module at `github.com/secforge/lib`. Subpackages:

```
github.com/secforge/lib/oidc      # OIDC provider abstraction
github.com/secforge/lib/secrets   # secret-store + per-app bootstrap abstraction
github.com/secforge/lib/authzn    # authorization-engine abstraction
```

Phase 6b-1 will add `github.com/secforge/lib/api-auth` as a fourth subpackage
(JWT + DPoP middleware) per [ADR-0014](../../docs/02-decisions/0014-api-auth-library-design.md).

## Consumer setup

Apps under `apps/<name>/` add a local `replace` directive in their `go.mod`:

```go
require github.com/secforge/lib v0.0.0

replace github.com/secforge/lib => ../lib
```

This stays a local replace until the platform repo grows a separate
versioning story for shared libs.
