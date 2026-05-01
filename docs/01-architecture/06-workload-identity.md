# Workload Identity (SPIRE) — Local Edition

> Companion ADR: [ADR-0005 — SPIRE Architecture (Local Edition)](../02-decisions/0005-spire-architecture-local.md).
> Operations: [SPIRE upstream CA rotation runbook](../03-runbooks/spire-ca-rotation.md), [SPIRE rotation runbook](../03-runbooks/spire-rotation.md).
> Naming convention: [SPIFFE ID naming](../06-reference/spiffe-ids.md).

This document describes how every workload in the SecForge cluster gets a cryptographic identity, how that identity is attested, and how it rotates. The architecture is identical to the cloud edition — only the upstream signing authority changes.

---

## Goals

1. **Every pod has a unique, attested identity** before it talks to anything sensitive (Keycloak, OpenBao, SpiceDB, the database, MinIO).
2. **Identities are short-lived and rotate automatically.** No 30-day API keys.
3. **Identity issuance is bound to the platform's attestation surface** — service account + namespace + node — not to a static secret.
4. **The same SPIFFE IDs work locally and in cloud.** Trust domain naming differs (`secforge.local` vs `dev.secforge.internal`); the structure is the same.

---

## Trust domain

`spiffe://secforge.local`

A single trust domain for the local cluster. No federation. The cloud edition will use a different trust domain per environment (e.g., `spiffe://dev.secforge.internal`); migration is a re-bootstrap, not a federated handoff, since dev → prod boundaries should not be crossed by SVIDs.

---

## SPIFFE ID naming convention

```
spiffe://secforge.local/ns/{namespace}/sa/{serviceaccount}
```

Examples:

| Workload | SPIFFE ID |
|---|---|
| BFF in `app` ns, SA `bff` | `spiffe://secforge.local/ns/app/sa/bff` |
| Keycloak in `keycloak` ns, SA `keycloak` | `spiffe://secforge.local/ns/keycloak/sa/keycloak` |
| OpenBao in `openbao` ns, SA `openbao` | `spiffe://secforge.local/ns/openbao/sa/openbao` |
| SpiceDB in `spicedb` ns, SA `spicedb` | `spiffe://secforge.local/ns/spicedb/sa/spicedb` |
| Test workload in `test-spire` ns, SA `test-app` | `spiffe://secforge.local/ns/test-spire/sa/test-app` |

The full naming reference (including how to add `/component/...` segments for sub-identities when one workload presents multiple personas) is in [docs/06-reference/spiffe-ids.md](../06-reference/spiffe-ids.md).

---

## Components, as deployed

```
┌──────────────────────────────────────────────────────────────────────┐
│                  Docker Desktop Kubernetes (single node)              │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ namespace: spire                                                 │ │
│  │                                                                  │ │
│  │  ┌───────────────────────────┐                                  │ │
│  │  │ spire-server (StatefulSet)│  ← upstream CA mounted from K8s  │ │
│  │  │  - SQLite datastore        │     Secret `spire-upstream-ca`  │ │
│  │  │  - UpstreamAuthority: disk │                                 │ │
│  │  │  - NodeAttestor: k8s_psat  │                                 │ │
│  │  │  - JWT issuer + JWKS       │                                 │ │
│  │  └─────────────┬─────────────┘                                  │ │
│  │                │                                                 │ │
│  │  ┌─────────────▼─────────────┐  ┌──────────────────────────────┐│ │
│  │  │ spire-agent (DaemonSet)   │  │ spire-controller-manager     ││ │
│  │  │  - WorkloadAttestor: k8s, │  │  - Reconciles ClusterSPIFFEID││ │
│  │  │    unix                   │  │    CRDs into registrations   ││ │
│  │  │  - Workload API socket on │  │                              ││ │
│  │  │    /run/spire/agent-       │  └──────────────────────────────┘│ │
│  │  │    sockets/spire-agent.sock│                                 │ │
│  │  └─────────────┬─────────────┘                                  │ │
│  │                │                                                 │ │
│  │  ┌─────────────▼─────────────┐                                  │ │
│  │  │ spiffe-csi-driver          │  ← exposes the agent socket as  │ │
│  │  │ (DaemonSet)                │     a CSI volume to workload    │ │
│  │  │                            │     pods                        │ │
│  │  └────────────────────────────┘                                 │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ namespace: app, keycloak, openbao, spicedb, istio-system, ...   │ │
│  │                                                                  │ │
│  │   workload pods mount the spiffe CSI volume at                  │ │
│  │   /spiffe-workload-api/spire-agent.sock and call the Workload   │ │
│  │   API to fetch their X.509-SVID and JWT-SVID.                   │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### spire-server (StatefulSet, 1 replica)

- **Datastore:** SQLite on a PVC. Single replica. No HA.
- **UpstreamAuthority:** the `disk` plugin, reading `cert-file-path` and `key-file-path` from `/run/spire/upstream/`. The K8s Secret `spire-upstream-ca` is projected into that mount.
- **CA materials:** generated once with `openssl` (ECDSA P-256, self-signed, 10-year validity — Ed25519 is **not** supported by SPIRE's `disk` UpstreamAuthority plugin). Stored as a K8s Secret in the `spire` namespace under keys `tls.crt`/`tls.key`. The Secret cannot be `get`-ed by any ServiceAccount via the K8s API; it is only made available via kubelet-mediated volume mount on the spire-server pod. See [the CA rotation runbook](../03-runbooks/spire-ca-rotation.md).
- **NodeAttestor:** `k8s_psat` (Projected Service Account Token). The agent sends a projected SA token; the server verifies it against the Kubernetes API. PSAT is the right choice for any K8s, including Docker Desktop, where there is no cloud metadata service to attest against.
- **TTLs:**
  - X.509-SVID: 1 hour (rotated at 50% — agents request a refresh at ~30 minutes).
  - JWT-SVID: 5 minutes (issued on demand; not cached on disk).
  - Default CA TTL: 24 hours (intermediate; the upstream root is the long-lived disk material).
- **Audit logging:** structured JSON to STDOUT. Captured by Promtail → Loki when observability is in place.

### spire-agent (DaemonSet)

- One pod per node (single node locally; production-realistic shape).
- **WorkloadAttestor plugins:** `k8s` (matches workload pod by Kubernetes selectors — namespace, service account, pod label) and `unix` (matches by Linux UID/GID).
- Runs as a non-root user; needs hostPath mounts for `/var/run/secrets/kubernetes.io/...` (PSAT) and the workload API socket directory.
- Exposes the SPIFFE Workload API on a Unix domain socket inside its hostPath directory; the CSI driver makes that socket available to workload pods on demand.

### spire-controller-manager

- Reconciles `ClusterSPIFFEID` and `ClusterFederatedTrustDomain` CRDs into SPIRE server registrations. This is how we declare "pods matching X get SPIFFE ID Y" without manually shelling into the server.
- Single replica.

### spire-spiffe-csi-driver

- A CSI driver that exposes the spire-agent's Workload API socket inside workload pods as a volume.
- Workload pods mount it at `/spiffe-workload-api`. Inside the pod, the SPIFFE workload helper libraries (`go-spiffe/v2`, the equivalents in other languages) connect to `/spiffe-workload-api/spire-agent.sock` and request SVIDs.

---

## How a workload gets its identity

```
1. Pod starts. It carries label `spiffe.io/spire-managed-identity: true`
   and mounts the `spiffe-csi-driver` volume at /spiffe-workload-api.

2. spire-controller-manager has already converted the matching
   ClusterSPIFFEID into a registration on the spire-server, keyed on:
     - kubernetes namespace
     - kubernetes serviceaccount
     - kubernetes pod label

3. Workload code calls go-spiffe's WorkloadAPIClient. Under the hood,
   that opens /spiffe-workload-api/spire-agent.sock and issues a
   FetchX509SVID RPC.

4. spire-agent looks up the calling process's UID/GID and Kubernetes
   selectors (it can see the pod via the kubelet API), matches it
   against registrations, and fetches an SVID from spire-server if
   one isn't cached.

5. The X.509-SVID comes back as a leaf cert + chain + private key,
   already signed by the upstream root CA. The workload uses it for
   mTLS / JWT validation / etc.

6. The agent rotates the SVID at 50% of TTL. The workload helper
   library transparently swaps in the new material — no restart needed.
```

---

## Registration model

Two patterns:

### Pattern 1: Opt-in by label (the default)

A `ClusterSPIFFEID` with a `podSelector` matching the label `spiffe.io/spire-managed-identity: "true"`. Pods that should have an identity must add this label. This is the safe default — it forces explicit consent.

The "default" registration uses this pattern and templates the SPIFFE ID from namespace and service account, so any opted-in pod automatically gets `spiffe://secforge.local/ns/{namespace}/sa/{serviceaccount}`.

### Pattern 2: Namespace-scoped (for namespaces where every pod gets an identity)

For platform components — `keycloak`, `spicedb`, `openbao`, `app`, `istio-system` — we additionally create namespace-scoped `ClusterSPIFFEID` resources with a `namespaceSelector`, so every pod in that namespace gets an identity without having to set the label. We still keep the SPIFFE ID template the same (namespace + service account), so the naming convention is consistent regardless of how the pod was selected.

The registration manifests live in `infrastructure/spire/cluster-spiffe-ids.yaml`.

---

## What this enables (and what it doesn't, yet)

**Enables:**
- Service-to-service mTLS via Istio (Phase 6) using SVIDs as the workload identity.
- Authentication to OpenBao via JWT-SVID (Phase 5; pattern documented in [spire-openbao-pattern.md](../06-reference/spire-openbao-pattern.md)).
- Workload-bound database credentials (OpenBao DB engine, Phase 5+).

**Does NOT enable yet:**
- Federation to AWS IAM / GCP / Azure AD. There is no cloud trust anchor on the other side. This is the architectural gap the cloud edition fills with `aws_iid` + `aws_sts` style IAM federation. SPIRE is ready to federate when a cloud trust anchor exists.

---

## Hardening posture

| Property | Value (verified Phase 2.7) | Rationale |
|---|---|---|
| Upstream CA private key location | K8s Secret `spire-upstream-ca`, namespace `spire` | Not on host disk; the local copy was shredded after import. |
| Secret access RBAC | `kubectl auth can-i get` returns "no" for every ServiceAccount we tested (including spire-server's own) | The Secret cannot be enumerated via the K8s API. It is delivered to spire-server only via the kubelet's projected volume. |
| Secret in-pod permissions | Mounted into spire-server-0 only; no other pod has it | Single-pod blast radius. |
| spire-server RBAC | ClusterRole grants only `tokenreviews`, `nodes:get/list`, `pods:get/list` | Minimum needed for `k8s_psat` attestor + workload selector lookup. |
| spire-server runtime | `runAsNonRoot: true`, `runAsUser: 1000`, `readOnlyRootFilesystem: true`, `capabilities.drop: ALL` | Fully restricted. |
| spire-agent runtime | container `runAsUser: 1000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ALL` | Pod-level cannot enforce `runAsNonRoot` because the chart's `fsgroupfix` init container needs UID 0 to chown the socket directory. |
| spire-agent host mounts | only `/run/spire/agent-sockets/` (DirectoryOrCreate) | Minimum needed for the WorkloadAPI socket. |
| SVID TTL | `default_x509_svid_ttl: 1h`, `default_jwt_svid_ttl: 5m`, `ca_ttl: 24h` | Short enough that revocation is bounded by rotation. |
| SVID rotation | 50% of TTL | Agent refreshes proactively; no rotation gaps. |
| Identity opt-in | label `spiffe.io/spire-managed-identity: true` (Pattern 1) or namespace-scoped registration (Pattern 2) | No accidental identities. |
| Wildcards in SPIFFE ID templates | None — all 6 active `ClusterSPIFFEID` resources use `ns/{ns}/sa/{sa}` | Every registration produces a deterministic ID derived from real attestation selectors. |
| Audit logging | spire-server emits structured JSON to STDOUT, including `"type":"audit"` events for every API access | Picked up by Loki / Wazuh in Phase 7. Verified working. |

---

## Verification — how to know it's working

```bash
# Server and agent healthy
kubectl get pods -n spire

# Server bundle / JWKS exposed (used by OpenBao + downstream JWT verifiers)
kubectl exec -n spire deploy/spire-server -- spire-server bundle show

# A test workload sees its SPIFFE ID
kubectl exec -n test-spire deploy/spiffe-test -- /app/spiffe-test
```

Expected output of the test workload (Phase 2.5):

```
SPIFFE ID:   spiffe://secforge.local/ns/test-spire/sa/test-app
Not before:  2026-04-29T11:00:00Z
Not after:   2026-04-29T12:00:00Z
Issuer CN:   SecForge Local SPIRE Root CA
JWT-SVID:    eyJ...{base64 token}...
```

---

## Cloud-migration notes

When this platform moves to a cloud destination, the following pieces change:

| Local | Cloud equivalent |
|---|---|
| Disk-based UpstreamAuthority (`disk` plugin) | KMS-backed UpstreamAuthority (`aws_kms`, `gcp_cloudkms`, `azure_keyvault` plugins) |
| K8s Secret with file-CA | KMS-managed key with no file copy |
| `spiffe://secforge.local` | `spiffe://dev.secforge.internal`, `spiffe://prod.secforge.internal`, ... per environment |
| `k8s_psat` node attestor only | `aws_iid` / `gcp_iit` / `azure_msi` *plus* `k8s_psat` |
| SQLite datastore | Postgres (RDS) for the spire-server |

Workload manifests (the `spiffe.io/spire-managed-identity` label, the CSI volume mount) do **not** change at migration time. That's the whole point of the SPIFFE abstraction.
