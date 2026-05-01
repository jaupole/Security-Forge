# helloworld-bff

Backend-for-Frontend service for the SecForge Local Edition.

**Wire contract**: `docs/01-architecture/04-bff-pattern.md` (single source of truth for behaviour).
**Replicas decision**: `docs/02-decisions/0011-bff-single-replica-local.md`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/login` | Start OIDC PAR + DPoP auth-code flow against Keycloak. `?next=/path` controls post-login redirect. |
| GET | `/callback` | OIDC code exchange. Sets `__Host-bff_sid` cookie, redirects to `next`. |
| POST | `/logout` | CSRF-checked. Local invalidate FIRST, best-effort revoke, KC end-session redirect. |
| ALL | `/api/*` | Reverse-proxy to backend with `Authorization: DPoP <jwt>` + per-call DPoP proof. |
| ALL | `/*` | Reverse-proxy to frontend with `X-CSP-Nonce` request header. |
| GET | `/healthz` | Liveness — always 200. |
| GET | `/ready` | Readiness — Valkey + Keycloak issuer probe. |

## Configuration

Pure environment variables (`BFF_*` prefix). Required:

| Var | Example | Notes |
|---|---|---|
| `BFF_PUBLIC_ORIGIN` | `https://app.secforge.local` | Drives htu canon + cookie scope. Must equal what `X-Forwarded-Host` on inbound requests resolves to. |
| `BFF_KEYCLOAK_ISSUER` | `https://auth.secforge.local/realms/secforge-tenants` | OIDC discovery base. |
| `BFF_KEYCLOAK_CLIENT_ID` | `helloworld-bff` | Pre-provisioned in Phase 3.5. |
| `BFF_VALKEY_ADDR` | `valkey-primary.valkey.svc.cluster.local:6379` | host:port. |
| `BFF_OPENBAO_ADDR` | `https://openbao.openbao.svc.cluster.local:8200` | OpenBao API base. |

Optional:

| Var | Default | Notes |
|---|---|---|
| `BFF_BACKEND_URL` | (empty) | When unset, `/api/*` returns 502 (Phase 9 lights it up). |
| `BFF_FRONTEND_URL` | (empty) | When unset, `/*` returns 502 (Phase 9 lights it up). |
| `BFF_OPENBAO_ROLE` | `helloworld-bff` | jwt-auth role name. |
| `BFF_OPENBAO_SVID_PATH` | `/shared/openbao.jwt` | Where the spiffe-helper init container wrote the JWT-SVID. |
| `BFF_OPENBAO_KV_PATH` | `secret/data/keycloak/clients/helloworld-bff` | KV-v2 path holding `private_pem`. |
| `BFF_LISTEN_ADDR` | `:3000` | TCP listen address. |

## Bootstrap secret flow (startup)

1. `spiffe-helper` init container fetches a JWT-SVID with `aud=openbao` (audience required by the OpenBao jwt-auth config) and writes it to `/shared/openbao.jwt`.
2. BFF starts, reads the JWT, exchanges for an OpenBao token via `auth/jwt/login` (role=`helloworld-bff`).
3. BFF reads `secret/data/keycloak/clients/helloworld-bff` and pulls `private_pem`.
4. BFF parses the PEM into an `*rsa.PrivateKey` for `private_key_jwt` Keycloak client assertion.
5. The OpenBao token is discarded; the private key lives in process memory only.

The BFF never persists the private key, never writes it to disk, never logs it.

## Build

```sh
docker build -t helloworld-bff:0.1.0 apps/helloworld-bff
```

Produces a static-linked, distroless binary, runs as nonroot UID 65532.

## Deviations from the Phase 6 prompt

- `replicas: 1` instead of 2 — see `docs/02-decisions/0011-bff-single-replica-local.md`.
- DPoP keypair is per-pod, in-memory only. Pod restart triggers a transparent token refresh on the first post-restart upstream call (refresh tokens are intentionally not DPoP-bound at Keycloak).
