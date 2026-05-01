# SPIRE → OpenBao Authentication Pattern

> **Status (2026-04-29):** Documented for Phase 5 implementation. SPIRE is deployed and exposing the JWT-SVID signing key on the trust bundle (verified: `kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show -format spiffe`). The OpenBao side will be wired up in Phase 5.

This is the canonical pattern for any workload in the cluster that needs to authenticate to OpenBao to fetch dynamic secrets, database credentials, or KV values. It does **not** require a long-lived OpenBao token, a Kubernetes ServiceAccount token, or anything pre-shared. The workload's SPIFFE identity is the credential.

---

## The flow at a glance

```
Workload pod                         OpenBao                           SPIRE
────────────                         ───────                           ─────
   │                                    │                                │
   │ 1. Workload API: FetchJWTSVID      │                                │
   │    (audience = "openbao")          │                                │
   ├────────────────────────────────────┼────────────────────────────────►
   │ ◄────── JWT-SVID ──────────────────┼────────────────────────────────┤
   │                                    │                                │
   │ 2. POST /v1/auth/jwt/login         │                                │
   │    { "role": "<role>", "jwt": …}   │                                │
   ├───────────────────────────────────►│                                │
   │                                    │ 3. Verify JWT signature        │
   │                                    │    via JWKS (cached)           │
   │                                    │ ◄──────────────────────────────┤
   │                                    │ 4. Match `sub` SPIFFE ID       │
   │                                    │    against role's allowed list │
   │                                    │ 5. Issue OpenBao token         │
   │ ◄───── token + lease ──────────────┤                                │
   │                                    │                                │
   │ 6. GET /v1/secret/data/...         │                                │
   │    X-Vault-Token: <token>          │                                │
   ├───────────────────────────────────►│                                │
```

The workload never holds a long-lived secret. The JWT-SVID lasts 5 minutes; the OpenBao token lives only as long as the role's TTL.

---

## Step-by-step setup

### On the SPIRE side (one-time per workload)

The workload's pod must:
1. Live in a namespace covered by a `ClusterSPIFFEID` registration (either via the `spiffe.io/spire-managed-identity: "true"` label, or a namespace-scoped registration in `infrastructure/spire/cluster-spiffe-ids.yaml`).
2. Mount the SPIFFE CSI driver volume:
   ```yaml
   volumes:
     - name: spiffe-workload-api
       csi:
         driver: csi.spiffe.io
         readOnly: true
   # in the container:
   volumeMounts:
     - name: spiffe-workload-api
       mountPath: /spiffe-workload-api
       readOnly: true
   ```

Nothing else. SPIRE issues identities to qualifying pods automatically.

### On the OpenBao side (Phase 5)

#### 1. Enable the JWT auth method

```bash
bao auth enable -path=spire jwt
```

#### 2. Configure OpenBao to trust SPIRE's JWKS

SPIRE doesn't expose a standard OIDC `/.well-known/openid-configuration` by default — that's what the `spiffe-oidc-discovery-provider` subchart is for. We enable that in Phase 5 alongside OpenBao:

```yaml
# infrastructure/spire/values.yaml — Phase 5 overlay
spiffe-oidc-discovery-provider:
  enabled: true
  service:
    type: ClusterIP
  ingress:
    enabled: false   # internal only
```

The discovery provider will then expose `https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local/keys` (and a `/.well-known/openid-configuration` document pointing at it).

In OpenBao:

```bash
bao write auth/spire/config \
    oidc_discovery_url="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
    oidc_discovery_ca_pem=@/run/spire/ca.pem \
    bound_issuer="https://oidc-discovery.secforge.local"
```

The `bound_issuer` value must match the `iss` claim that SPIRE puts in the JWT-SVID — observed in Phase 2.5 as `https://oidc-discovery.secforge.local`.

#### 3. Define a role per consuming workload

Example for the BFF (`spiffe://secforge.local/ns/app/sa/bff`):

```bash
bao write auth/spire/role/app-bff \
    role_type=jwt \
    bound_audiences="openbao" \
    user_claim="sub" \
    bound_subject="spiffe://secforge.local/ns/app/sa/bff" \
    token_policies="app-bff" \
    token_ttl="15m" \
    token_max_ttl="1h"
```

The `bound_audiences` value MUST match the audience the workload requests when it calls `FetchJWTSVID`. **The audience is what binds the JWT to the OpenBao role** — a JWT issued for audience "openbao" cannot be replayed against any other consumer.

#### 4. Workload code (Go, with go-spiffe/v2)

```go
import (
    "github.com/spiffe/go-spiffe/v2/svid/jwtsvid"
    "github.com/spiffe/go-spiffe/v2/workloadapi"
)

client, _ := workloadapi.New(ctx)
defer client.Close()

myID := spiffeid.RequireFromString("spiffe://secforge.local/ns/app/sa/bff")
jwt, _ := client.FetchJWTSVID(ctx, jwtsvid.Params{
    Audience: "openbao",
    Subject:  myID,
})

resp := vaultClient.Logical().Write("auth/spire/login", map[string]any{
    "role": "app-bff",
    "jwt":  jwt.Marshal(),
})
// resp.Auth.ClientToken is now usable for the lease lifetime.
```

The workload should refresh the OpenBao token before its lease expires; the token itself can be renewed without re-authenticating, but each renewal requires a still-valid JWT-SVID for the rebinding case (e.g., after restart).

---

## Why this is better than the K8s ServiceAccount JWT path

OpenBao also supports authenticating via the K8s `kubernetes` auth method, which trusts ServiceAccount tokens. That works, and it's the obvious fallback. But:

| Property | K8s auth method | SPIRE JWT-SVID |
|---|---|---|
| Token lifetime | Bound to pod lifetime (default ~1h projected, configurable) | 5 minutes |
| Audience binding | Single audience per token (`vault` or whatever the projection requested) | Per-call audience — different audiences for different downstream services |
| Rotation cadence | Token rotated by kubelet (~1h) | SVID rotated by SPIRE every 30m at 50% of TTL |
| Identity scope | `system:serviceaccount:<ns>:<sa>` — opaque | SPIFFE ID with structured trust-domain + path — same shape across clusters / clouds |
| Cross-cluster portability | None (token issuer differs per cluster) | Trust-domain-scoped; a federated SPIRE setup makes cross-cluster work natively |
| Audit context | "the SA token signed by api-server" | "the JWT-SVID signed by SPIRE for an attested workload" — strictly stronger claim |

We use SPIRE for everything that's a workload-to-platform-service auth boundary, and we keep the Kubernetes auth method available as a defense-in-depth fallback only.

---

## Verification (once Phase 5 is up)

1. `bao read auth/spire/config` should show the SPIRE JWKS URL and `bound_issuer`.
2. `bao read auth/spire/role/app-bff` should show the SPIFFE ID binding.
3. From inside a workload pod:
   ```bash
   kubectl exec -n app deploy/bff -- /app/healthcheck --self-test=openbao
   ```
   The health-check should fetch a JWT-SVID, exchange it for an OpenBao token, and read a known KV path — all without any long-lived credential mounted.
4. The OpenBao audit log should record:
   ```
   auth.spire login type=jwt sub=spiffe://secforge.local/ns/app/sa/bff role=app-bff
   ```

## Pitfalls (learned the hard way elsewhere)

- The `bound_issuer` MUST match the JWT's `iss` claim **exactly**. SPIRE's default `iss` is `https://oidc-discovery.{trust-domain}` — not the cluster URL.
- The JWT audience is **case-sensitive** and must match `bound_audiences`.
- If you change SPIRE's CA, OpenBao's cached JWKS will eventually refresh, but you can force a re-fetch by re-writing the auth/jwt/config.
- For workloads that fork into multiple roles (e.g., a BFF that talks to OpenBao for both DB creds and KV), use **multiple OpenBao roles bound to the same SPIFFE ID with different audiences**, so each role has its own minimal token policy. Don't share one role across responsibilities.
