# Phase 6 — Service Mesh and BFF

> **Navigation:** ⬅ [Previous: Phase 5 — OpenBao](./phase-05-openbao.md) · [Next: Phase 6.10b — VSO + secret cleanup](./phase-06.10b-vso-and-secret-cleanup.md) ➡ · [📋 PLAN.md](../../PLAN.md) · [Phase prompts index](./README.md)
>
> **Depends on (must be ✅):** Phases 0–5
> **Blocks:** Phase 6.10b, 6b-0, 6b-1, 6b-2, 7, 7b, 7c, 7d, 8, 9, 10, 11
>
> **Status (mirrors PLAN.md, last updated 2026-05-01):** ✅ Complete (2026-04-30). Istio Ambient + helloworld-bff live. 6.10b folded into the same flow.
>
> PLAN.md is the source of truth for phase status. If this block diverges from PLAN.md's quick-ref table, **PLAN.md wins**; update this block in the same edit that bumps PLAN.md.

**Estimated time:** 4-5 days

**Prerequisites:** Phases 1-5 complete.

---

## Goal of this phase

Deploy Istio Ambient mode with SPIRE as external CA. Build the BFF service in Go that the Hello World app will use.

---

## What you (the human) need to do first

1. Read the BFF section of `docs/01-architecture/00-overview.md`.
2. Confirm SPIRE (Phase 2) is healthy and serving identities.
3. Allow extra time — Istio Ambient + external CA + SPIRE has more pieces than vanilla Istio.

---

## Keycloak clients required (verify before starting)

The BFF performs an OAuth 2.1 Authorization Code + PAR + DPoP flow against Keycloak. This phase **uses existing clients from Phase 3.5**, not new ones — but verify they're present and configured before starting.

| Client ID | Realm | Confidential | Redirect URI | Created in |
|---|---|---|---|---|
| `helloworld-bff` | `secforge-tenants` | yes (client-jwt / private_key_jwt PS256) | `https://app.secforge.local/auth/callback` | Phase 3.5 |
| `proposal-forge-bff` | `secforge-tenants` | yes (client-jwt) | `https://pf.secforge.local/auth/callback` | Phase 3.5 |
| `project-tracker-bff` | `secforge-tenants` | yes (client-jwt) | `https://pt.secforge.local/auth/callback` | Phase 3.5 |
| `pm-bff` | `secforge-tenants` | yes (client-jwt) | `https://pm.secforge.local/auth/callback` | Phase 3.5 |

Verify with:
```bash
bash infrastructure/keycloak/verify.sh
# expects KCADM_USER + KCADM_PASSWORD + KCADM_TOTP for the full client check
```

Each client must have:
- `private_key_jwt` auth (PS256), with the BFF's public key registered (matches `app/bff-jwt-<id>` Secret + `secret/data/keycloak/clients/<id>` in OpenBao)
- PAR + DPoP + PKCE-S256 required
- Implicit, ROPC, CIBA, device flows disabled

If any client's redirect URI changed since Phase 3.5 (e.g., you renamed an app's hostname), update via `infrastructure/keycloak/realms/bootstrap-bff-clients.sh` (idempotent) before starting this phase. The BFF's `oidc.go` will fail to redirect through Keycloak if the URI doesn't match exactly.

No new client is needed for Istio Ambient itself — the mesh authenticates workloads via SPIFFE-SVIDs (Phase 2), not OIDC.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 6 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-06-istio-bff.md before doing anything.

Three parts: (0) Phase 5 housekeeping, (a) Istio Ambient with SPIRE as external CA, (b) the BFF service — including the OpenBao secrets cutover that makes OpenBao authoritative for the Phase 5.10 migrated secrets.

## Part 0: Phase 5 housekeeping (do this first)

### Phase 6.0.1 — Decommission idle CNPG cluster

Phase 5 follow-up: the `secforge-openbao-db` CNPG cluster created in Phase 1 for Postgres-backed OpenBao storage is unused (we run Raft instead). Delete it cleanly:

```
kubectl delete cluster secforge-openbao-db -n openbao
kubectl get pvc -n openbao -l cnpg.io/cluster=secforge-openbao-db
# delete any orphaned PVCs from the above
```

Confirm `kubectl get pods -n openbao` shows only OpenBao pods afterward. Update PLAN.md to mark follow-up #2 as done.

### Phase 6.0.2 — Verify Phase 5.10 secrets are in sync

Before Part B's cutover deletes the K8s Secret copies, verify the OpenBao copies still match what consumers are reading today:

- `secret/data/spicedb/preshared-key` matches the value in `spicedb/spicedb-config` K8s Secret
- `secret/data/keycloak/clients/<id>` for each of the 4 BFFs matches the corresponding `app/bff-jwt-<id>` Secret

If anything drifted, re-run the Phase 5.10 migration script before continuing.

## Part A: Istio Ambient

### Phase 6.1 — Design

Document in docs/01-architecture/07-service-mesh.md:
- Istio version: latest stable supporting Ambient + external CA + cert-manager-csi-driver-spiffe (1.24+)
- Mode: Ambient (no sidecars; ztunnel L4, waypoint proxies for L7)
- CA: SPIRE via cert-manager-csi-driver-spiffe
- AuthorizationPolicy: SPIFFE-ID-based
- Telemetry: traces to Tempo, metrics to Prometheus, structured access logs

### Phase 6.2 — Install Istio

Use istioctl with a custom IstioOperator:
- Profile: ambient
- meshConfig: external CA enabled
- Disable auto-injected sidecar
- mTLS STRICT mode

Install order:
1. istio-base
2. istiod
3. ztunnel
4. CNI plugin
5. cert-manager-csi-driver-spiffe (configured with SPIRE)

Label `app` namespace for ambient mode:
```
kubectl label namespace app istio.io/dataplane-mode=ambient
```

### Phase 6.3 — AuthorizationPolicy baseline

Default-deny in `app` namespace:
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: app
spec: {}
```

Then explicit allows as we add services. Document patterns in docs/03-runbooks/istio-authz.md.

### Phase 6.4 — Verify mTLS

Deploy a test pair (`service-a`, `service-b`) in `app` namespace:
- AuthorizationPolicy: service-a can call service-b on /healthz
- Verify legitimate calls succeed, untrusted calls denied, plaintext denied

## Part B: BFF service

### Phase 6.5 — BFF design

Document in docs/01-architecture/04-bff-pattern.md:

The BFF:
- Accepts browser requests with opaque session cookie (httpOnly, Secure, SameSite=Lax, ~32 bytes random)
- Looks up session in Valkey to get stored OAuth tokens
- Refreshes tokens automatically near expiry
- Calls backend with DPoP-bound JWT
- Returns result to browser
- Handles login flow:
  - GET /login → start OIDC PAR + DPoP auth code flow with Keycloak
  - GET /callback → complete code exchange, store tokens in Valkey, set session cookie, redirect
  - POST /logout → revoke tokens, delete session, clear cookie, redirect to Keycloak end-session
- Sets strict CSP, HSTS, X-Frame-Options DENY on every response

### Phase 6.6 — Implement the BFF

Create `apps/helloworld-bff/`:
- `main.go` — entry point
- `oidc.go` — OIDC client (use github.com/coreos/go-oidc/v3)
- `dpop.go` — DPoP proof generation (github.com/lestrrat-go/jwx/v2)
- `session.go` — Valkey session store
- `proxy.go` — reverse proxy to backend with DPoP-bound JWT injection
- `headers.go` — security headers middleware
- `Dockerfile` — multi-stage, distroless final image, runs as nonroot UID 65532
- `kubernetes/` — manifests (Deployment, Service, ServiceAccount, AuthorizationPolicy, Ingress)
- `README.md`

Constraints:
- ~300-500 lines total
- Configuration via env vars only
- Secrets fetched from OpenBao at startup via SPIFFE-bound JWT auth
- Health endpoint /healthz, ready /ready
- Structured JSON logging with request IDs
- OpenTelemetry instrumentation
- Graceful shutdown on SIGTERM

DPoP implementation:
- Generate fresh ECDSA P-256 keypair on startup, in memory only
- Send public key thumbprint `jkt` to Keycloak in token request so issued tokens are bound
- Mint fresh DPoP proof JWT for each upstream call (with `htm`, `htu`, `iat`, `jti`, `ath`)

### Phase 6.7 — Build and sign image

- Multi-stage Dockerfile, distroless/static final
- Sign with Cosign using the local key (Phase 1)
- Generate SBOM with Syft
- Scan with Trivy and Grype, fail on critical CVEs
- Build using `docker build` and load directly into Docker Desktop K8s with `docker tag` (no registry needed locally — Docker Desktop's K8s shares the Docker daemon)

### Phase 6.8 — Deploy BFF

- 2 replicas in `app` namespace
- ServiceAccount `helloworld-bff` with corresponding OpenBao role
- Pod label `spiffe.io/spire-managed-identity: "true"`
- Identity: `spiffe://secforge.local/ns/app/sa/helloworld-bff`
- AuthorizationPolicy allowing BFF to call:
  - The backend (Phase 9)
  - The AuthZEN façade (Phase 4)
- Public Ingress at `https://app.secforge.local` with cert from cert-manager
- HPA on CPU and request rate

### Phase 6.9 — Verify

Without backend or frontend yet:
1. Visit https://app.secforge.local/login
2. Get redirected to Keycloak
3. Authenticate with passkey
4. Get redirected back; verify session cookie is set, opaque, httpOnly, Secure, SameSite=Lax
5. /api/* will 502 (no backend yet) — but verify BFF logs show DPoP proof and JWT going upstream
6. /logout — verify tokens revoked, cookie cleared

### Phase 6.10 — Security headers

Use `curl -I https://app.secforge.local` to verify:
- Content-Security-Policy: nonce-based
- Strict-Transport-Security: max-age 63072000; includeSubDomains; preload
- X-Frame-Options: DENY
- X-Content-Type-Options: nosniff
- Referrer-Policy: strict-origin-when-cross-origin
- Permissions-Policy: deny camera, microphone, geolocation, etc.

### Phase 6.10b — VSO install + secret cutover cleanup

**Extracted to its own prompt doc:** [phase-06.10b-vso-and-secret-cleanup.md](./phase-06.10b-vso-and-secret-cleanup.md).

Originally inline here as "cutover Phase 5.10 secrets." Grew to a 6-step plan: install Vault Secrets Operator + cutover SpiceDB + AuthZEN + refactor `bootstrap-bff-clients.sh` + delete redundant K8s Secrets. Decision pattern (asymmetric VSO + direct-API distribution) is recorded in [ADR-0015](../02-decisions/0015-secret-distribution-pattern.md).

Run the extracted prompt doc as its own working session — keeps right-pane context clean and gives ADR-0015 a stable reference target.

### Phase 6.11 — Documentation

Update:
- docs/01-architecture/04-bff-pattern.md
- docs/01-architecture/07-service-mesh.md
- docs/03-runbooks/bff-operations.md
- docs/03-runbooks/istio-authz.md
- docs/02-decisions/0006-istio-ambient-vs-sidecar.md

## Constraints

- BFF code short and auditable
- No tokens in browser. Cookies only.
- DPoP keypair lives in memory only
- Secrets from OpenBao via SPIFFE-bound auth, never env or files
- All upstream calls have DPoP proof + JWT
- Default-deny AuthorizationPolicy everywhere
- Image signed with Cosign before deploy
- Security headers achieve A+ on SecurityHeaders.com (test via the public site if you publish your local URL via ngrok temporarily, or use a local equivalent like https://github.com/observatory-cli)
```

---

## Success criteria

- [ ] Istio Ambient deployed, ztunnel running
- [ ] mTLS verified, default-deny AuthorizationPolicy in `app`
- [ ] BFF deployed, healthy, login flow works end-to-end with passkey
- [ ] Session cookie meets all hardening criteria
- [ ] DPoP proof generated and bound correctly
- [ ] Security headers all present
- [ ] BFF image signed, admitted by Kyverno
- [ ] `secforge-openbao-db` CNPG cluster deleted (Phase 5 follow-up #2 closed)
- [ ] OpenBao is sole source of truth for Phase 5.10 secrets; redundant K8s Secret copies deleted; SpiceDB and BFFs verified working post-cutover
- [ ] Documentation and ADRs updated; PLAN.md updated

---

## Troubleshooting

### "Istio Ambient pods not captured by ztunnel"
Verify the namespace label. `kubectl get ztunnel -A` and check ztunnel logs.

### "AuthorizationPolicy denies legitimate requests"
`istioctl x authz check <pod>` to debug. SPIFFE ID in policy must match SPIRE-issued ID exactly.

### "BFF can't validate Keycloak JWTs"
JWKS URL in BFF config must match Keycloak's JWKS. Network connectivity from BFF to Keycloak (in-cluster, should just work).

### "DPoP validation fails downstream"
`htu` and `htm` must match exactly. Trailing slashes matter. Query strings matter.

---

## What's next

[Phase 7 — Observability](./phase-07-observability.md).
