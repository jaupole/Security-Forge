# Architecture Overview

This document is the high-level mental model of how the SecForge platform components fit together on
the single public Hetzner bare-metal k3s node. For deep dives on individual components, see the
per-component docs in this directory.

---

## The big picture, in one paragraph

A user hits an application served at `https://members.secforge.dev` (or another public surface). The
browser talks to a **BFF / app server** which holds OAuth tokens server-side. The user was
authenticated by a redirect to **Keycloak** at `https://auth.secforge.dev`, where they proved who
they are with a **passkey**. When calling backend services the app presents a short-lived
**DPoP-bound JWT**; backends validate the JWT, then call **SpiceDB** to ask "is this user allowed to
do this on this resource?" Service-to-service traffic runs through **Istio Ambient** with mTLS, where
every workload identity is a **SPIFFE ID** (`spiffe://secforge.platform/...`) issued by **SPIRE**.
Secrets and dynamic database credentials come from **OpenBao**. Everything emits logs to **Wazuh**
for SIEM, metrics to **Prometheus + Grafana**, and traces to **Tempo**. Container images are signed
keylessly with **Cosign** (GitHub OIDC) and **Kyverno** enforces signature verification, digest
pinning, and the platform's security policies at admission. Ingress is the **Istio gateway**, split
into a public gateway and a tailnet-only gateway for operator surfaces.

If that paragraph makes sense, you understand the architecture. The rest is detail.

---

## Invariants (the security model)

These hold regardless of substrate:

- **Authentication** uses OIDC + Auth Code + PKCE + PAR + DPoP, with **passkeys** (WebAuthn) as the
  factor (see [ADR-0036](../02-decisions/0036-production-authentication-factors-passkeys.md)).
- **Authorization** uses SpiceDB with the three-tier model (tenant / app / resource).
- **Browser pattern**: the browser never holds OAuth tokens — server-side sessions only.
- **Workload identity**: SPIRE-issued SPIFFE IDs from Kubernetes-native attestation.
- **mTLS everywhere** between services via Istio Ambient.
- **Secrets** go through OpenBao with short-lived dynamic credentials for databases.
- **Audit logging, metrics, traces** flow to Wazuh / Prometheus / Tempo.

---

## Substrate

This is a single public bare-metal node. The architecture maps cleanly onto managed cloud if it ever
migrates; the table shows the equivalence.

| Concept | This deployment (Hetzner bare-metal) | Managed-cloud equivalent |
|---|---|---|
| SPIRE trust domain | `spiffe://secforge.platform` (Istio mesh trustDomain `cluster.local`) | per-env trust domain |
| Cluster | single-node k3s (`65.21.25.40`) | EKS / GKE / AKS |
| Postgres | CloudNativePG (Postgres 17.6) in-cluster | RDS / Cloud SQL |
| Object storage | MinIO (dedicated partition, SSE-S3) | S3 / GCS / Azure Blob |
| KMS | OpenBao Transit | AWS KMS / Cloud KMS |
| Cloud IAM | none — SPIFFE-bound OpenBao roles | AWS IAM + IRSA |
| DNS | real public DNS for `*.secforge.dev` | Route 53 / Cloud DNS |
| TLS issuer | cert-manager + Let's Encrypt | cert-manager + Let's Encrypt |
| Image signing | Cosign **keyless** via GitHub OIDC | same |
| Ingress | Istio gateway (`secforge-gateway` public + `secforge-gateway-tailnet`) | cloud LB + Istio gateway |
| Operator access | Tailscale tailnet (no Teleport) | bastion / VPN + tailnet |
| Multi-environment | one node, namespace separation | accounts/projects per env |

It's a single node, so defense-in-depth is layered *within* the cluster (NetworkPolicies, Istio
AuthorizationPolicy + STRICT mTLS, Kyverno admission, per-app DBs + RLS) rather than across separate
accounts/VPCs.

---

## Component-by-component

### The applications

The deployed ecosystem: **Ecosystem Portal** (tenant shell, `portal`), **Ecosystem Control**
(control plane + operator/admin shell, `control`/`admin`), **Member Hub** (`members`), and
**Proposal Forge** (`pf`, tailnet-only). **Project Tracker** (the PM app) has its identity/schema
provisioned but is not yet deployed.

### App servers + frontends

App backends hold OAuth tokens server-side and present DPoP-bound JWTs to other services; frontends
are SPAs that call only their own server, never seeing OAuth tokens. The ecosystem apps use
**HttpOnly-cookie sessions** (Keycloak-driven). The Go **BFF** reference pattern
(`apps/lib/api-auth`, `apps/lib/secrets`) is the template for new first-class services.

### Keycloak

Deployed via the Keycloak Operator on a custom signed image (`ghcr.io/jaupole/keycloak`), Postgres
(CNPG) backend. Realms:
- `platform` — operators/admins; `browser-webauthn-required` (mandatory passkey).
- `secforge-tenants` — tenants/members; `browser-flexible` (password-or-passkey + optional 2FA).

Public OIDC at `https://auth.secforge.dev`; the admin console at `https://kc.secforge.dev` is
**tailnet-only**. The master-realm admin is WebAuthn-required and DB-only.

### SpiceDB

Authorization engine, CNPG-backed datastore, datastore URI rotated via the refresher pattern
(ADR-0023).

### OpenBao

Secrets + Transit KMS + dynamic DB credentials. Sealed with **Transit auto-unseal** from a separate
seal instance (ADR-0009); 3 nodes + 1 seal node. VSO renders operator-shaped secrets; first-class
apps fetch via `apps/lib/secrets` (ADR-0015).

### SPIRE

Trust domain `spiffe://secforge.platform`. Workloads call OpenBao via the Workload API (JWT-SVID).

### Istio Ambient

mTLS everywhere. Ingress is the Istio gateway (public + tailnet split, enforced by the Kyverno
`admin-ingress-must-be-tailnet-only` policy). Replaced EOL ingress-nginx (ADR-0032).

### Operator access (Tailscale)

Privileged access is the Tailscale tailnet — host SSH (public `:22` closed) and the tailnet-only
admin gateway. No Teleport (ADR-0035). See
[09-privileged-access.md](./09-privileged-access.md).

### Observability & SIEM

Wazuh (manager + indexer, dedicated partition), Loki + Promtail, kube-prometheus-stack,
OpenTelemetry → Tempo.

### Supply chain

Cosign **keyless** via GitHub OIDC against public Sigstore Rekor; Kyverno enforces
`verify-image-signature-*`, `require-image-digest`, `disallow-latest-tag`, and the secret-env /
run-as-nonroot / resource-limit policies; Trivy Operator (ClientServer) scans images.

---

## Data flows

### Login flow (recap)

```
User → members.secforge.dev (app)
     → app: "no session, redirect"
     → auth.secforge.dev (Keycloak)
     → Keycloak: passkey prompt
     → User authenticates with passkey
     → Keycloak issues authorization code, redirects back
     → app exchanges code for tokens (PAR + DPoP)
     → app sets an HttpOnly session cookie
     → app redirects user to original URL
```

### Authenticated API call (recap)

```
Browser → app (with HttpOnly cookie)
       → app mints DPoP proof, calls backend with JWT + DPoP header
       → backend validates JWT (signature against Keycloak JWKS)
       → backend validates DPoP (thumbprint matches cnf.jkt in JWT)
       → backend asks SpiceDB: "can user:jason view document:4471?"
       → backend returns data (or 403)
```

---

## Where things are NOT

- **OAuth tokens do not live in the browser.** Ever. HttpOnly cookies only.
- **Static service credentials do not exist.** No long-lived API keys between our services.
- **Production database credentials do not exist statically.** Apps fetch fresh ones from OpenBao.
- **Plain-text secrets do not live in Git.** Ever.
- **Authorization decisions do not live in application code.** They live in SpiceDB.

---

## NetworkPolicy contract

**Every namespace MUST have a default-deny-ingress NetworkPolicy.** This is a structural rule, not a
per-component preference. New namespaces start locked down; explicit ALLOWs are documented in each
component's architecture doc and in the NetworkPolicy YAML's per-rule comment.

### What "default-deny-ingress" means here

A NetworkPolicy with `policyTypes: [Ingress]` and an empty `podSelector: {}` denies ALL inbound pod
traffic in the target namespace by default. Subsequent NetworkPolicies whose `podSelector` matches
specific workloads grant explicit ALLOWs (per-pod, per-port, per-source-namespace or
per-source-pod-label). Enforcement is by the k3s CNI on every packet entering the namespace's pods;
lateral-movement control is layered with Istio AuthorizationPolicy + STRICT mTLS via ztunnel.

### Verification command

```bash
# Every active app/platform namespace must show at least one default-deny NP.
for ns in $(kubectl get ns -o name | sed 's|namespace/||' | grep -vE '^(kube-|default$)'); do
  count=$(kubectl get networkpolicy -n "$ns" -o name 2>/dev/null | wc -l)
  echo "$ns: $count NP(s)"
done
```

A namespace with zero NetworkPolicies is a defect. Egress NetworkPolicies are present where they add
value (Layer A default-deny applied to most platform namespaces) but are not universal — the model
relies on Istio AuthorizationPolicy + ztunnel for most lateral-movement controls.

### When to NOT add a default-deny

Almost never. The exceptions are namespaces that are themselves the security boundary
(`kube-system` — kubelet/control-plane traffic, managed by the CNI). Any new namespace that warrants
an exception MUST justify it in writing here before being admitted.
