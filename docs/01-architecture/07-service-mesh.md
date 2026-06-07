# Service Mesh (Istio Ambient + SPIRE)

> **Production note.** Written for the local edition; the Istio Ambient model below is unchanged in production (pilot 1.30.0). Substrate deltas: the cluster is **Hetzner k3s** single node (not Docker Desktop); **ingress is the Istio gateway** (`secforge-gateway` public + `secforge-gateway-tailnet`), which replaced ingress-nginx ([ADR-0032](../02-decisions/0032-istio-gateway-replaces-ingress-nginx.md)); the SPIRE trust domain is **`secforge.platform`**. See [PLAN.md](../../PLAN.md) and [00-overview.md](./00-overview.md).

> Companion ADR: [ADR-0010 — Istio Ambient vs. Sidecar (with SPIRE-CA deferral)](../02-decisions/0010-istio-ambient-vs-sidecar.md).
> Operational runbook: [Istio AuthorizationPolicy patterns](../03-runbooks/istio-authz.md).
> Identity: [Workload Identity (SPIRE)](./06-workload-identity.md).

This document describes the **target** state: every pod-to-pod hop is mTLS-protected, identified by a SPIRE-issued SPIFFE ID, and authorized by least-privilege `AuthorizationPolicy`. The cloud edition is identical except for the SPIRE upstream-CA backing (file vs. KMS).

> **Interim state (Phase 6.2 → 6.2b):** Phase 6.2 ships Ambient with **Istio's built-in CA**, not SPIRE. Workload-to-OpenBao, workload-to-SpiceDB, and any flow using the SPIRE Workload API socket continue to use SPIRE-issued IDs (`spiffe://secforge.platform/ns/.../sa/...`). Mesh peer mTLS uses Istio-CA-issued IDs (`spiffe://cluster.local/ns/.../sa/...`). The two trust domains coexist; AuthorizationPolicies in `app` reference `spiffe://cluster.local/...` until 6.2b cuts over. See ADR-0010 for the deferral rationale and timing.

---

## Goals

1. **Every in-cluster connection is mutually authenticated.** No plaintext, no anonymous callers, no namespace boundary that depends on `NetworkPolicy` alone.
2. **Workload identity is the SPIFFE ID issued by SPIRE**, not the K8s ServiceAccount JWT or an Istio-issued cert from a separate CA.
3. **Default-deny in `app`.** Any new service must opt itself into reachability via an explicit `AuthorizationPolicy`.
4. **No sidecars on workload pods.** L4 mTLS happens in `ztunnel` (per-node DaemonSet); L7 policy is enforced by waypoint proxies, deployed only where needed.
5. **Same manifests work in cloud.** Only the SPIRE trust domain and upstream CA change.

---

## Mode: Ambient, not sidecar

Istio offers two data-plane modes:

- **Sidecar**: a co-located Envoy in every workload pod. Captures all pod traffic. Mature and feature-complete. Cost: ~150 MB RAM and ~50ms p99 latency overhead per pod, mutating-webhook injection complications, and tight coupling between sidecar lifecycle and workload pod restarts.
- **Ambient**: no sidecars. `ztunnel` (a DaemonSet on every node, written in Rust) handles L4 mTLS for the pods on that node. L7 policies (HTTP routing, JWT validation, header-based authz) are evaluated in **waypoint proxies** — separate Deployments scoped per service-account or per namespace, deployed only where L7 features are needed.

We choose **Ambient**. Rationale captured in [ADR-0010](../02-decisions/0010-istio-ambient-vs-sidecar.md). The short version: lower per-pod cost; the platform's existing components (Keycloak, SpiceDB, OpenBao) all run as charts that don't natively support sidecar injection without patches; ztunnel + waypoints separate concerns cleanly.

---

## Components, as deployed

```
┌──────────────────────────────────────────────────────────────────────┐
│                  Docker Desktop Kubernetes (single node)              │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ namespace: istio-system                                          │ │
│  │                                                                  │ │
│  │  ┌───────────────────────────────┐                              │ │
│  │  │ istiod (Deployment, 1 replica) │  ← issues mesh config        │ │
│  │  │  - Config + xDS                │     to ztunnel + waypoints   │ │
│  │  │  - External CA: SPIRE via      │     SVIDs are the workload   │ │
│  │  │    cert-manager-csi-driver-    │     identity; istiod itself  │ │
│  │  │    spiffe                      │     does NOT mint workload   │ │
│  │  │  - meshConfig.trustDomain =    │     certs.                   │ │
│  │  │    secforge.dev              │                              │ │
│  │  └───────────────────────────────┘                              │ │
│  │                                                                  │ │
│  │  ┌───────────────────────────────┐                              │ │
│  │  │ ztunnel (DaemonSet)            │  ← per-node L4 dataplane.   │ │
│  │  │  - Receives SVID via the       │     Captures pods labeled    │ │
│  │  │    SPIFFE Workload API socket  │     istio.io/dataplane-mode= │ │
│  │  │  - HBONE tunnel between nodes  │     ambient via the CNI     │ │
│  │  │  - Enforces PeerAuthentication │     plugin's redirect.       │ │
│  │  │  - Speaks ext-authz to         │                              │ │
│  │  │    waypoints when present      │                              │ │
│  │  └───────────────────────────────┘                              │ │
│  │                                                                  │ │
│  │  ┌───────────────────────────────┐                              │ │
│  │  │ istio-cni (DaemonSet)          │  ← chains into the cluster's │ │
│  │  │  - Adds redirect rules so      │     CNI; redirects traffic   │ │
│  │  │    workload traffic enters     │     of ambient-labeled pods  │ │
│  │  │    ztunnel transparently       │     into ztunnel.            │ │
│  │  └───────────────────────────────┘                              │ │
│  │                                                                  │ │
│  │  ┌───────────────────────────────┐                              │ │
│  │  │ cert-manager-csi-driver-spiffe │  ← presents X.509-SVIDs as   │ │
│  │  │ (DaemonSet)                    │     volume mounts to ztunnel │ │
│  │  │  - Talks to SPIRE Workload API │     and waypoints. Bridges   │ │
│  │  │  - Materialises SVIDs as       │     SPIRE's UDS Workload API │ │
│  │  │    cert-manager Issuer         │     into the cert-manager    │ │
│  │  │    "spiffe" CSR signer         │     CSR signing protocol     │ │
│  │  │                                │     that Istio expects.      │ │
│  │  └───────────────────────────────┘                              │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ namespace: app  (label: istio.io/dataplane-mode=ambient)         │ │
│  │                                                                  │ │
│  │   workload pods (BFF, backends, AuthZEN façade) — no sidecars.  │ │
│  │   Their traffic is captured by ztunnel via the istio-cni        │ │
│  │   redirect; the SPIRE-issued SVID identifies them.              │ │
│  │                                                                  │ │
│  │   Optional: a waypoint Deployment per service-account (e.g.     │ │
│  │   "helloworld-bff-waypoint") for L7 policies. Only deployed     │ │
│  │   where we need HTTP-level rules.                               │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### istiod

- **1 replica.** No HA locally; fine.
- **CA (Phase 6.2 interim)**: Istio's built-in Citadel. Mints `spiffe://cluster.local/ns/{ns}/sa/{sa}` for ztunnel and waypoints. PeerAuthentication remains STRICT.
- **CA (target, Phase 6.2b)**: SPIRE Workload API mounted into istiod, ztunnel, and CNI. Istiod no longer signs workload certs; each component fetches its SVID from SPIRE. trustDomain becomes `secforge.dev`. AuthorizationPolicies move from `spiffe://cluster.local/...` to `spiffe://secforge.platform/...`.
- **PeerAuthentication (Phase 6.2 interim)**: `PERMISSIVE` mesh-wide. Mesh peers prefer mTLS; non-mesh peers (ingress-nginx, openbao→postgres, kubelet probes) are tolerated. Tightens to `STRICT` once every legitimate caller is mesh-resident or has an explicit AuthorizationPolicy ALLOW.

### ztunnel

- **DaemonSet** (1 pod on the single local node; same shape on multi-node clusters).
- **Identity**: ztunnel itself runs with SPIFFE ID `spiffe://secforge.platform/ns/istio-system/sa/ztunnel`. It uses an SVID from cert-manager-csi-driver-spiffe.
- **HBONE tunnel** (HTTP/2 CONNECT over mTLS, TCP/**15008**) is the wire format between ztunnels. Even on a **single node** the hop still rides HBONE on 15008 (it is *not* a no-op for the data path — `NetworkPolicy` sees 15008, not the app port). Cross-node hops are HBONE-encrypted the same way. **This has a hard NetworkPolicy consequence — see ["Ambient + Kubernetes NetworkPolicy"](#ambient--kubernetes-networkpolicy) below.**
- **L4 enforcement**: applies `PeerAuthentication` (always STRICT here) and any `AuthorizationPolicy` rules that resolve at L4 (e.g., allow/deny by SPIFFE ID, by namespace, by ports).

### istio-cni

- **DaemonSet**, runs once at node bootstrap. Installs CNI plugin chain entries that redirect ambient-labeled pod traffic into ztunnel. No persistent process; the plugin runs at pod-attach time per pod.
- This is where the "no sidecar" magic happens: the redirect is at the CNI/iptables layer, not in the pod itself.

### cert-manager-csi-driver-spiffe

- **DaemonSet.** Bridges between two protocols:
  - **SPIRE Workload API** (Unix-domain socket, `FetchX509SVID` RPC). Same protocol used by every other workload that wants an SVID.
  - **cert-manager CSR signing** (`spiffe://...` URIs in CertificateSigningRequests, signed by an Issuer of type `csi-driver-spiffe`). This is what Istio's external-CA integration expects.
- **Why not have istiod call SPIRE directly?** Istio's external-CA integration reads from a cert-manager Issuer interface. Going through cert-manager-csi-driver-spiffe is the canonical path; it also gives us a clean audit trail and the ability to reuse the same Issuer for non-Istio workloads that need cert-manager-issued SVIDs.
- **Identity of the driver itself**: `spiffe://secforge.platform/ns/istio-system/sa/cert-manager-csi-driver-spiffe`.

### Waypoints (deployed on demand, not by default)

- **Per service-account or per namespace**, depending on policy granularity needed.
- Waypoints are full Envoys; they handle L7 features that ztunnel intentionally doesn't (HTTP routing, JWT-claim-based authz, header rewriting, retries, circuit breakers).
- We only deploy waypoints where L7 policies are needed — initially just in front of the BFF (Phase 6.8) for L7 AuthorizationPolicies tying the BFF's downstream calls to specific paths/methods.
- A pod's traffic flows: workload pod → istio-cni redirect → local ztunnel → (L4 policy here) → cross-node HBONE → remote ztunnel → optional remote waypoint (L7 policy here) → destination workload pod.

---

## Identity model

### Target state (Phase 6.2b)

| Caller | SPIFFE ID (one universe) |
|---|---|
| ztunnel pod | `spiffe://secforge.platform/ns/istio-system/sa/ztunnel` |
| BFF pod | `spiffe://secforge.platform/ns/app/sa/helloworld-bff` |
| AuthZEN façade pod | `spiffe://secforge.platform/ns/app/sa/authzen-facade` |
| SpiceDB pod | `spiffe://secforge.platform/ns/spicedb/sa/spicedb` |
| Keycloak pod | `spiffe://secforge.platform/ns/keycloak/sa/keycloak` |
| OpenBao pod | `spiffe://secforge.platform/ns/openbao/sa/openbao` |

**Critical invariant** (post-6.2b): the same SPIFFE ID a workload presents to OpenBao (Phase 5 JWT-SVID auth) is the one Istio uses for mTLS peer identification. No "Istio identity" separate from the "platform identity."

### Interim state (Phase 6.2 → 6.2b)

Two trust domains coexist temporarily:

| Caller | What ztunnel sees on the wire (Istio CA) | What OpenBao / SpiceDB sees (SPIRE) |
|---|---|---|
| ztunnel pod | `spiffe://cluster.local/ns/istio-system/sa/ztunnel` | n/a (ztunnel doesn't authenticate to OpenBao/SpiceDB) |
| BFF pod | `spiffe://cluster.local/ns/app/sa/helloworld-bff` | `spiffe://secforge.platform/ns/app/sa/helloworld-bff` |
| Backend pod | `spiffe://cluster.local/ns/app/sa/<name>` | `spiffe://secforge.platform/ns/app/sa/<name>` |
| AuthZEN façade pod | `spiffe://cluster.local/ns/app/sa/authzen-facade` | `spiffe://secforge.platform/ns/app/sa/authzen-facade` |
| SpiceDB / Keycloak / OpenBao | unchanged (those namespaces are not ambient-labeled in 6.2) | `spiffe://secforge.platform/ns/<ns>/sa/<sa>` |

**AuthorizationPolicies in `app` reference `spiffe://cluster.local/...` principals during this interim** — that's what ztunnel actually sees. They will be rewritten in 6.2b. App-layer code (BFF→OpenBao, backend→SpiceDB peer-mTLS, etc.) continues to read SPIRE-issued SVIDs from `spiffe-csi`; that path doesn't change.

---

## AuthorizationPolicy: default-deny in `app`

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
    name: default-deny
    namespace: app
spec: {}
```

An empty `spec: {}` policy denies all traffic. Each new service that needs to be reachable adds an explicit ALLOW policy naming the SPIFFE IDs of its callers.

**Pattern for service-to-service allow:**

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
    name: bff-can-call-helloworld-backend
    namespace: app
spec:
    selector:
        matchLabels:
            app: helloworld-backend
    action: ALLOW
    rules:
    - from:
        - source:
                principals:
                - "spiffe://secforge.platform/ns/app/sa/helloworld-bff"
        to:
        - operation:
                paths: ["/api/*"]
                methods: ["GET", "POST"]
```

We use **principals** (SPIFFE IDs), never `namespaces` or `serviceAccounts`, because principals match the actual SVID on the wire. Namespace/SA matching is convenient but lossy — it can be spoofed by a misconfigured admission policy or a renamed pod; an SVID cannot.

> **Interim caveat (Phase 6.2 → 6.2b):** the principal string is `spiffe://cluster.local/...` not `spiffe://secforge.platform/...` until the SPIRE-CA cutover. Same value structure (`/ns/{ns}/sa/{sa}`), different trust-domain prefix. Examples in this doc and the runbook will be updated when 6.2b lands.

The full set of patterns (gateway-from-internet, BFF-to-backend, backend-to-SpiceDB, backend-to-OpenBao, etc.) is in [docs/03-runbooks/istio-authz.md](../03-runbooks/istio-authz.md).

### Other namespaces

- `keycloak`, `spicedb`, `openbao`, `spire`, `istio-system`: **not** ambient-labeled in Phase 6. We add them later only if there's a concrete reason (e.g., we want SpiceDB-to-Postgres traffic to flow through the mesh). Keeping them out reduces blast radius during the initial Ambient rollout.
- `app`: ambient + default-deny + per-service ALLOW policies. This is where the BFF, backends, and the AuthZEN façade live.

---

## Ambient + Kubernetes NetworkPolicy

> **Incident 2026-06-03.** Member Hub (`members.secforge.dev`) black-screened after
> login. Root cause was a NetworkPolicy gap, not the app. This section exists so it
> never recurs.

`NetworkPolicy` (enforced by the CNI at L3/L4) and Ambient (ztunnel) **stack**, and
they interact in one non-obvious way:

- When a pod talks to a pod in **another ambient namespace**, ztunnel tunnels the
  connection ztunnel→ztunnel over **HBONE on TCP/15008** — *not* the application
  port. So a `NetworkPolicy` that only allows the app port (e.g. `4000`) **blocks the
  actual mesh traffic**. ztunnel accepts the client connection, fails to open the
  upstream HBONE leg, and the caller sees **`Connection reset by peer`** (a RST — note
  it is *not* a clean timeout, which is what a plain L4 drop looks like).

**The rule:** any cross-namespace `NetworkPolicy` between **two ambient namespaces**
MUST allow `TCP/15008` (HBONE) on **both** ends — the caller's egress rule *and* the
callee's ingress rule — in addition to the app port. Keep the app-port rule too (it
covers the pre/non-Ambient path and is harmless).

```yaml
# callee ingress (and mirror on the caller's egress)
ports:
  - { protocol: TCP, port: 4000 }    # app port (pre/non-Ambient path)
  - { protocol: TCP, port: 15008 }   # HBONE — Istio Ambient ztunnel mesh tunnel
```

**What is and isn't affected:**

| Path | Mesh transport | NetworkPolicy needs |
|---|---|---|
| ambient ns ↔ **same** ns (intra-namespace) | HBONE, but intra-ns rules usually allow all ports (`ports: []`) | nothing extra |
| ambient ns ↔ **other ambient** ns | HBONE on 15008 | **15008 on both ends** + app port |
| ambient ns ↔ **non-ambient** ns (keycloak, spicedb, openbao, minio, ingress-nginx) | plain L4 on the app port | app port only (unchanged) |

**Operational notes:**

- Source identity is preserved across the HBONE tunnel, so `from:`/`to:`
  `namespaceSelector` (and pod selectors) still match — you only add the port.
- When you join a namespace to the mesh (`istio.io/dataplane-mode: ambient`), audit
  every cross-namespace `NetworkPolicy` it has *to or from another ambient namespace*
  and add 15008. The `bootstrap-app.sh` namespace template carries a warning for this.
- Diagnose with a throwaway pod in the caller ns (labelled to match the egress
  selector, with a PSS-restricted `securityContext`) doing
  `wget http://<svc>.<ns>.svc.cluster.local/healthz`: a **RST** points here; a
  **timeout** points at a missing app-port allow or AuthorizationPolicy DENY.
- Fixed paths so far: `member-hub ↔ control`. Audit (2026-06-03) confirmed it was the
  only *complete* cross-ambient app path; the OTel app→observability and PF→control
  rules are one-ended (blocked at the far end regardless), so they were never working
  and are tracked separately, not as Ambient regressions.

---

## Telemetry

Wired in Phase 7 (Observability). For now, the hooks exist:

- **Access logs**: ztunnel and waypoints emit JSON access logs. Each line carries `source.principal`, `destination.principal`, `method`, `path`, `responseCode`, `duration`. Promtail ships them to Loki.
- **Metrics**: ztunnel and waypoints expose Prometheus metrics on the standard `istio_*` series. ServiceMonitors in Phase 7.
- **Traces**: workloads instrumented with OpenTelemetry continue to control their own tracing; the mesh injects/propagates `traceparent` on B3 fallback. Tempo collects in Phase 7.

---

## Hardening posture

| Property | Value | Rationale |
|---|---|---|
| mTLS mode | `STRICT` mesh-wide via `PeerAuthentication` | Plaintext is denied at L4 by ztunnel. |
| Default authz | DENY in `app` namespace | Every reachable path opts in explicitly. |
| Authz match | SPIFFE IDs only (`principals`), never `namespaces`/`serviceAccounts` | Identity comes from the cert, not from labels. |
| Workload CA | SPIRE via cert-manager-csi-driver-spiffe | One CA, one trust domain, one identity per workload. |
| Sidecar admission | Disabled (no namespaces are sidecar-injected) | Ambient only; no parallel mode. |
| Waypoint scope | Per-service-account, deployed on demand | Smallest blast radius; only deployed where L7 rules exist. |
| Image signing | Cosign-signed istiod, ztunnel, waypoints; Kyverno verifies (Audit locally per ADR-0004) | Same supply-chain rules as platform images. |
| Resource limits | Memory + CPU set on istiod, ztunnel, csi-driver-spiffe | Local-resource discipline; matches PSS-restricted requirements elsewhere. |
| `runAsNonRoot` | true on every Istio pod | Already the chart default; verified by Kyverno PSS-restricted. |

---

## Verification

Phase 6.4 runs an end-to-end test pair (`service-a`, `service-b`) in the `app` namespace and verifies:

1. **Legitimate call works.** `service-a` → `service-b/healthz` via cluster DNS returns 200. ztunnel logs show `source.principal=spiffe://.../sa/service-a`, `destination.principal=spiffe://.../sa/service-b`.
2. **Unauthorized SPIFFE ID denied.** A third pod without an `AuthorizationPolicy` allow gets 403 from ztunnel.
3. **Plaintext denied.** A pod that bypasses the workload library and tries plain HTTP to `service-b` gets RST or "no peer cert" — STRICT mTLS is enforced.

The test manifests live in `infrastructure/istio/test/`.

---

## What this enables

- **BFF (Phase 6.8) → backend (Phase 9)**: mTLS automatic; SPIFFE-ID-based AuthorizationPolicy.
- **Backend → SpiceDB**: same. SpiceDB's existing gRPC-mTLS keeps working — the inner cert is what SpiceDB's peer-cert validation reads; ztunnel adds an outer mTLS hop on top. (We may revisit dropping the inner mTLS once we trust the mesh; not in Phase 6.)
- **Backend → OpenBao**: same. OpenBao's TLS listener still requires the SPIFFE-bound JWT-SVID for the auth decision; the mesh-level mTLS is an additional defense layer.
- **Backend → AuthZEN façade**: same.

---

## Cloud-migration notes

| Local | Cloud equivalent |
|---|---|
| SPIRE upstream CA = `disk` plugin | SPIRE upstream CA = KMS-backed plugin (`aws_kms` etc.) |
| `spiffe://secforge.platform` trust domain | `spiffe://dev.secforge.internal` (or per-env) |
| Single ztunnel pod | One ztunnel per node (DaemonSet shape unchanged) |
| Waypoints deployed per service-account | Same; HPA is the only addition |
| cert-manager-csi-driver-spiffe | Same (it's K8s-native; no cloud dependency) |
| AuthorizationPolicies | **Identical** — no rewrite at migration time |

The whole point of mesh-via-SPIFFE is that the policies travel unchanged between editions. The only thing that moves is the trust anchor.

---

## Why the target uses SPIRE, not Istiod-as-CA

Istio ships with `Istiod` as a CA out of the box. It works. But longer term:

- Istiod-as-CA mints its own SPIFFE-like IDs (`spiffe://cluster.local/ns/.../sa/...`), parallel to the SPIRE-issued ones. AuthorizationPolicies in `app` and JWT-SVID auth at OpenBao end up speaking different trust domains.
- Istiod-as-CA doesn't honor the existing SPIRE attestation surface (PSAT, k8s, unix). It re-attests via Kubernetes-native signals only — different machinery, different audit trail.
- Two trust domains in the same cluster doesn't survive cloud migration.

Phase 6.2b's SPIRE-as-Istio-CA cutover collapses the two universes. Phase 6.2 ships the mesh first; the cutover is a closeable deferral, not the steady state.
