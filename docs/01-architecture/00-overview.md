# Architecture Overview (Local Edition)

This document is the high-level mental model of how the SecForge platform components fit together on a local Docker Desktop Kubernetes cluster. The architecture is identical to the cloud edition; only the substrate beneath it changes.

For deep dives on individual components, see the per-component docs in this directory (filled in as you build).

---

## The big picture, in one paragraph

A user (your browser, on your laptop) hits an application served at `https://app.secforge.local`. The browser talks to a **BFF** (Backend-for-Frontend) which holds OAuth tokens server-side. The BFF authenticated the user by redirecting them to **Keycloak** at `https://auth.secforge.local`, where they proved who they are with a **passkey**. The BFF, when calling backend services, presents a short-lived **DPoP-bound JWT**. Backend services validate the JWT, then call **SpiceDB** to ask "is this user allowed to do this on this resource?" Service-to-service traffic runs through **Istio** with mTLS, where every service identity is a **SPIFFE ID** (`spiffe://secforge.local/...`) issued by **SPIRE**. Secrets and dynamic database credentials come from **OpenBao**. Everything emits structured logs to **Wazuh** for SIEM, metrics to **Prometheus + Grafana**, and traces to **Tempo**. Container images are signed with **Cosign** (local key); **Kyverno** can enforce signature verification (relaxed in dev). All of this runs on Docker Desktop's built-in single-node Kubernetes.

If that paragraph makes sense, you understand the architecture. The rest is detail.

---

## What's the same as the cloud edition

The protocols, the components, the security model, the data flows. Specifically:

- **Authentication** still uses OIDC + Auth Code + PKCE + PAR + DPoP, with passkeys as the primary factor.
- **Authorization** still uses SpiceDB with the three-tier model (platform / app / resource).
- **Browser pattern** still uses BFF; the browser never holds OAuth tokens.
- **Workload identity** still uses SPIRE-issued SPIFFE IDs, derived from the same Kubernetes-native attestation.
- **mTLS everywhere** between services via Istio Ambient mode + SPIRE.
- **Secrets** still go through OpenBao with short-lived dynamic credentials for databases.
- **Audit logging, metrics, traces** all flow to the same observability tooling.

---

## What's different from the cloud edition

What changes is the cloud-provided substrate that components sit on top of:

| Concept | Cloud | Local |
|---|---|---|
| Trust domain | `spiffe://dev.secforge.internal` | `spiffe://secforge.local` |
| Cluster | EKS | Docker Desktop K8s |
| Postgres | RDS | Postgres pods (CloudNativePG operator or Bitnami chart) |
| Object storage | S3 | MinIO |
| Cache | ElastiCache Valkey | Valkey pod |
| KMS | AWS KMS | OpenBao Transit + file-based root keys (mkcert + K8s Secrets) |
| Cloud IAM | AWS IAM + IRSA | None — replaced by SPIFFE-bound OpenBao roles |
| DNS | Route 53 | hosts file + `*.secforge.local` |
| TLS issuer | cert-manager + Let's Encrypt | cert-manager + mkcert local CA |
| Image signing | Cosign keyless via GitHub OIDC | Cosign with a local key |
| Bastion / privileged access | EC2 bastion + Teleport | Optional Teleport (or skip — direct kubectl works) |
| Multi-environment | Three accounts (dev/staging/prod) | One cluster, namespaces for separation if needed |

The cloud edition models defense-in-depth with multiple isolation boundaries (separate AWS accounts, separate VPCs, separate KMS keys, separate clusters). The local edition consolidates all of that to a single cluster — appropriate for development; not appropriate for production.

---

## Component-by-component (local edition specifics)

### The applications

You're building three: Proposal Forge, Project Tracker, future PM app. For Phase 9, we build a minimal Hello World demo first; for Phase 10, you start on the real apps.

### BFF + frontend

**BFF (Backend-for-Frontend)** — Identical to the cloud edition. Small Go service, ~300 lines, holds OAuth tokens server-side, opaque session cookie out, DPoP-bound JWT in.

**Frontend** — Static SPA. Calls only the BFF, never sees OAuth tokens.

Hosted at `https://app.secforge.local` via ingress-nginx.

### Keycloak

Same configuration as cloud. Deployed via Operator. Postgres backend (in-cluster Postgres pod). Realms:
- `platform` — your team
- `secforge-tenants` — SaaS-tier customers (with Keycloak Organizations enabled)

Hosted at `https://auth.secforge.local`. Admin console at `https://auth-admin.secforge.local` (which you can lock down with NetworkPolicy if you want, though locally it's just your laptop).

**Local difference**: Realm signing keys are stored in the database (Keycloak's default). The cloud edition uses AWS KMS via PKCS#11 for FIPS-grade key custody; that's an upgrade you make at cloud-migration time.

### SpiceDB

Same. Backed by an in-cluster Postgres pod.

### OpenBao

Same components, same auth methods, same secrets engines. Local difference:

**Auto-unseal**: in cloud we use AWS KMS auto-unseal. Locally, you have two options:
1. **Shamir unseal in dev mode** — acceptable for "I'm developing apps, this is my laptop." OpenBao starts unsealed automatically. Don't ever run this in production.
2. **Transit auto-unseal using a separate dev OpenBao** — closer to production. One OpenBao acts as the "KMS"; the main OpenBao seals/unseals using its Transit engine.

We default to option 2 because it teaches the production pattern. Documented in Phase 5.

### SPIRE

Same. Trust domain `spiffe://secforge.local`. The upstream CA private key is stored as a Kubernetes Secret instead of in cloud KMS — this is the one place where local genuinely is less secure, but the blast radius is your laptop.

**Local difference**: No federation to AWS IAM. Workloads that need to call OpenBao do so via SPIRE's Workload API (presenting their SPIFFE ID as a JWT-SVID, which OpenBao validates).

### Istio Ambient

Same. mTLS everywhere with SPIRE as external CA.

### Teleport

Optional locally. The strongest argument for keeping it: it's the production-realistic way humans access internal admin UIs (Wazuh dashboard, OpenBao UI, Grafana). If you skip it locally, document the gap and remember to add it before going live.

### Observability stack

- **Wazuh**: same as cloud, slimmed for resource use (1 manager, 1 indexer, 1 dashboard)
- **Loki + Promtail**: for application logs (alternative or complement to Wazuh)
- **kube-prometheus-stack**: metrics
- **OpenTelemetry → Tempo**: traces

### Supply chain

- **Cosign with a local key**: generate a keypair, commit the public key, sign builds with the private key. Less secure than keyless via GitHub OIDC but appropriate locally.
- **Kyverno**: enforces image signing. In dev, you can run Kyverno in `Audit` mode (logs violations but doesn't block); switch to `Enforce` when you're confident.
- **Trivy / Grype / Syft**: same scanning toolchain.

---

## Data flows

Identical to cloud edition. The flow diagrams in `iam-architecture-full-report.md` (when you save it into `docs/06-reference/`) apply directly.

### Login flow (recap)

```
User → app.secforge.local (BFF)
     → BFF: "no session, redirect"
     → auth.secforge.local (Keycloak)
     → Keycloak: passkey prompt
     → User taps FIDO2 key
     → Keycloak issues authorization code, redirects back
     → BFF exchanges code for tokens (PAR + DPoP)
     → BFF stores tokens in Valkey, sets opaque session cookie
     → BFF redirects user to original URL
     → User now sees the app
```

### Authenticated API call (recap)

```
Browser → BFF (with cookie)
       → BFF looks up session in Valkey
       → BFF mints DPoP proof, calls backend with JWT + DPoP header
       → Backend validates JWT (verify signature against Keycloak JWKS)
       → Backend validates DPoP (verify thumbprint matches `cnf.jkt` in JWT)
       → Backend asks SpiceDB: "can user:jason `view` document:4471?"
       → SpiceDB returns yes/no
       → Backend returns data (or 403)
       → BFF returns to browser
```

---

## Where things are NOT (still applies)

- **OAuth tokens do not live in the browser.** Ever. Cookies only.
- **Static service credentials do not exist.** No long-lived API keys between our services.
- **Production database credentials do not exist statically.** Apps fetch fresh ones from OpenBao.
- **Plain text secrets do not live in Git.** Ever.
- **Authorization decisions do not live in application code.** They live in SpiceDB.

These rules apply locally too — local is where you build the muscle memory.

---

## Resource budget

Approximate steady-state RAM per component on Docker Desktop K8s:

| Component | RAM | CPU |
|---|---|---|
| Postgres (5 databases or 1 with multiple) | ~512 MB | low |
| Valkey | ~256 MB | low |
| MinIO | ~256 MB | low |
| ingress-nginx | ~100 MB | low |
| cert-manager | ~150 MB | low |
| SPIRE server + agent | ~200 MB | low |
| Keycloak | ~1 GB | medium |
| SpiceDB + AuthZEN façade | ~300 MB | low |
| OpenBao | ~300 MB | low |
| Istio (ztunnel + control plane) | ~600 MB | medium |
| Wazuh (slimmed) | ~2 GB | medium |
| Prometheus + Grafana | ~700 MB | medium |
| Tempo + Loki | ~600 MB | medium |
| BFF | ~50 MB | low |
| Hello World backend | ~50 MB | low |
| **Total** | **~7 GB** | |

So 12 GB allocated to Docker Desktop is comfortable. 16 GB if you want headroom for your three apps too.

If pressure becomes an issue, the easy levers are: (a) skip Wazuh in favor of just Loki, (b) shut down components you're not actively using.

---

## Migration boundaries

When you migrate off local, here's what changes (roughly, in order of pain):

**Cheap to swap (Helm values changes)**:
- Postgres pod → managed Postgres (RDS, Cloud SQL, etc.)
- Valkey pod → managed Redis/Valkey
- MinIO → S3 / GCS / Azure Blob
- mkcert → Let's Encrypt or another real CA
- Hosts file DNS → real DNS

**Moderate (config + new infra)**:
- File-based KMS → AWS KMS / Cloud KMS / Azure Key Vault
- Local Kubernetes → managed Kubernetes (EKS / GKE / AKS)
- Cosign local keys → keyless via OIDC

**Significant (new pattern)**:
- SPIRE → cloud IAM federation (you add JWT-SVID → STS / GCP Workload Identity / Azure AD)
- Single cluster → multi-environment topology

The application code, Helm charts, BFF, SpiceDB schema, OpenBao policies — all of these move unchanged.

Migration playbooks live in `docs/06-reference/migration-to-vps.md` and `docs/06-reference/migration-to-aws.md` (created when you're ready to migrate).

---

## NetworkPolicy contract

**Every namespace MUST have a default-deny-ingress NetworkPolicy.** Closes F-ADR-6.

This is a structural rule, not a per-component preference. New namespaces start locked down; explicit ALLOWs are documented in each component's architecture doc and in the NetworkPolicy YAML's per-rule comment.

### What "default-deny-ingress" means here

A NetworkPolicy with `policyTypes: [Ingress]` and an empty `podSelector: {}` denies ALL inbound pod traffic in the target namespace by default. Subsequent NetworkPolicies whose `podSelector` matches specific workloads grant explicit ALLOWs (per-pod, per-port, per-source-namespace or per-source-pod-label).

CNI-level enforcement: Kindnet on Docker Desktop. The policy is evaluated by the CNI on every packet entering the namespace's pods.

### Verification command

```bash
# Every active app/platform namespace must show at least one default-deny NP.
for ns in $(kubectl get ns -o name | sed 's|namespace/||' | grep -vE '^(kube-|default$|local-path-storage)'); do
  count=$(kubectl get networkpolicy -n "$ns" -o name 2>/dev/null | wc -l)
  echo "$ns: $count NP(s)"
done
```

A namespace with zero NetworkPolicies is a defect. The fix-after-07 audit verified this holds today across all 8 platform/app namespaces (F-CLU-10 ✅); this section converts the *practice* into a *rule* so future namespaces inherit it.

### Egress

This contract covers **ingress**. Egress NetworkPolicies are present where they add value (BFF egress allowlist limits the BFF to Keycloak / Valkey / OpenBao / observability / authzen-facade — Phase 6) but are not universal: a default-deny-egress on a workload that talks to the K8s API surface tends to break operators' health probes in subtle ways, and the platform's security model relies on Istio AuthorizationPolicy + ztunnel rather than NetworkPolicy egress for most lateral movement controls. Future Phase 7c (PeerAuthentication STRICT) tightens this further.

### When to NOT add a default-deny

Almost never. The exceptions are namespaces that are themselves the security boundary:
- `kube-system` — kubelet/control-plane traffic; CNI manages this, not us.
- `local-path-storage` — single-node local volume provisioner; no security-relevant ingress.

Any new namespace that warrants an exception MUST justify in writing in this section before being admitted.
