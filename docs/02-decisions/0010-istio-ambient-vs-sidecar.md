# ADR-0010: Istio Ambient mode (not sidecar); SPIRE as external CA deferred

**Status**: Accepted (with deferral — see "Deferred: SPIRE as Istio's CA" below)
**Date**: 2026-04-29
**Decision-makers**: Jason Upole

## Context

Phase 6 needs a service mesh to enforce mTLS, SPIFFE-ID-based AuthorizationPolicies, and (later) L7 controls between platform components and the BFF. Two reasonable architectural choices exist:

1. **Istio sidecar mode** — co-located Envoy in every workload pod.
2. **Istio Ambient mode** — node-level `ztunnel` for L4, on-demand waypoint proxies for L7.

A separate but related question: who issues the workload mTLS certs?

1. **Istio's built-in CA (Istiod)** — mints `spiffe://cluster.local/...` IDs of its own.
2. **SPIRE as external CA via `cert-manager-csi-driver-spiffe`** — the same SVIDs the rest of the platform already uses.

Constraints:

- The platform already runs SPIRE (Phase 2) with trust domain `spiffe://secforge.local`. OpenBao (Phase 5), SpiceDB (Phase 4), and every workload already authenticate via SPIRE-issued JWT-SVIDs.
- Local resource budget is tight (~16 GB allocated to Docker Desktop K8s). Per-pod sidecar overhead matters.
- Several platform components (Keycloak Operator, OpenBao chart, SpiceDB Operator) deploy pods we don't fully control. Sidecar injection on operator-managed pods often requires patches or breaks lifecycle ordering.
- The cloud edition will run the same architecture; whatever works locally must port unchanged.

## Decision

**Use Istio Ambient mode** (ztunnel DaemonSet for L4; waypoints deployed per service-account on demand for L7).

**Defer SPIRE-as-external-CA to a follow-up sub-phase (6.2b).** Phase 6.2 ships Ambient with **Istio's default built-in CA** (Citadel-style; mints `spiffe://cluster.local/ns/{ns}/sa/{sa}` IDs).

PeerAuthentication: `STRICT` mesh-wide.
Default `AuthorizationPolicy` in `app` namespace: deny.

### Deferred: SPIRE as Istio's CA

The original write-up of this ADR proposed using `cert-manager-csi-driver-spiffe` as the bridge between Istio's external-CA interface and SPIRE's Workload API. On closer inspection, that chart is **not a SPIRE bridge** — it issues SPIFFE-formatted certs from a cert-manager Issuer of its own and does not consult SPIRE.

The genuine SPIRE-as-Istio-CA integration (https://istio.io/latest/docs/ops/integrations/spire/) is a heavier wiring job: SPIRE Workload API socket mounted into istiod, ztunnel, CNI, and csi-driver pods; custom `ClusterSPIFFEID` resources for each Istio component; Istio Helm values pointing each component at the SPIRE socket. The Ambient-specific story for that integration is younger and less documented than the sidecar version, with a realistic 1-2 day fiddle factor.

Until 6.2b lands, **two SPIFFE trust domains coexist**:

- Workload-to-OpenBao, workload-to-SpiceDB, workload-to-anything-using-`spiffe-csi`: SPIRE-issued IDs in `spiffe://secforge.local/...` (unchanged).
- ztunnel-to-ztunnel mTLS handshakes within the mesh: Istio-CA-issued IDs in `spiffe://cluster.local/ns/{ns}/sa/{sa}`.

For Phase 6's purposes, this is acceptable: AuthorizationPolicies in the `app` namespace match on Istio-CA principals (`spiffe://cluster.local/ns/app/sa/...`) since those are the IDs ztunnel sees on the wire. The platform's app-layer authentication (BFF JWT, OpenBao SPIFFE-JWT, SpiceDB peer-mTLS) continues to operate on SPIRE-issued IDs as before. The two universes don't interfere; they just don't yet collapse into one.

**Phase 6.2b commitments**:

- Mount SPIRE Workload API UDS into istiod, ztunnel, istio-cni, cert-manager-csi-driver-spiffe pods.
- Add `ClusterSPIFFEID` resources for `istiod`, `ztunnel`, `istio-cni-node`, `cert-manager-csi-driver-spiffe` (in `istio-system`).
- Reconfigure Istio Helm values to consume SPIRE-issued SVIDs for component identity and disable the built-in Citadel CA.
- Migrate `app`-namespace `AuthorizationPolicy` principals from `spiffe://cluster.local/...` to `spiffe://secforge.local/...`.
- Verify the test pair from Phase 6.4 still passes after the cutover.

**Scheduling**: Phase 7 (observability) or pre-migration hardening, whichever comes first. Doing it during Phase 7 has the advantage that Loki + Tempo are running, so the cutover is observable as it lands. Doing it pre-migration is the latest-acceptable boundary because the cloud edition cannot ship with a parallel identity universe.

**Re-evaluation criteria for the deferral itself**:

- A second admin needs to be added (the parallel-trust-domain story would force them to learn two names for everything).
- A future workload requires a unified identity for Istio AuthorizationPolicy *and* OpenBao auth in the same call (e.g., a service that wants to assert one identity to both the mesh peer and OpenBao via the same SVID). Today no Phase 6 workload needs this.
- Pre-migration hardening checklist starts.

## Rationale

**Ambient over sidecar**:

- **Resource cost**: sidecar Envoy adds ~150 MB RAM per pod. With ~25 pods at steady state, that's ~3.75 GB across the cluster — meaningful when Wazuh wants 2 GB and OpenBao wants 1.5 GB. Ambient amortizes the overhead to one ztunnel per node (~250 MB) and waypoints only where L7 features are used.
- **Lifecycle**: sidecar injection requires a mutating admission webhook and a pod restart. Ambient capture happens at the CNI redirect; existing pods are captured by relabeling the namespace, no restart required.
- **Operator-managed pods**: sidecar injection on Keycloak Operator-managed pods, OpenBao chart-managed pods, and the SpiceDB operator's pods consistently requires patches to PodSpec (resource limits, init container ordering, securityContext). Ambient sidesteps this entirely — the redirect is invisible to the pod.
- **Separation of concerns**: ztunnel (L4) and waypoints (L7) are separate processes; an L7 misconfiguration cannot brick L4 mTLS for the whole namespace. With sidecars, both run in the same Envoy.

**SPIRE as external CA over Istiod-as-CA** *(rationale for the eventual 6.2b state, not 6.2)*:

- **One identity universe.** Istiod-as-CA mints `spiffe://cluster.local/ns/.../sa/...`. SPIRE mints `spiffe://secforge.local/ns/.../sa/...`. With both in play, OpenBao validates one trust domain while ztunnel-to-ztunnel mTLS uses another; the platform's "the SPIFFE ID is the identity" invariant is broken in subtle ways. Going SPIRE-only eventually collapses this.
- **Same attestation surface.** SPIRE attests via PSAT (Phase 2). Istiod-as-CA re-attests via Kubernetes-native signals only (different machinery, different audit trail). Reusing SPIRE means the audit trail for "who got an SVID" is in one place.
- **Cloud parity.** The cloud edition cannot ship with two trust domains; the migration playbook assumes one. Closing this in 6.2b before pre-migration hardening prevents a hurried rip-and-replace.

## Alternatives considered and rejected

### Sidecar mode + Istiod as CA

- **Pros**: most documented, most "well-trodden path," richest L7 feature set with no waypoint indirection.
- **Cons**: per-pod resource cost; mutating-webhook on every namespace; the parallel-identity-universe problem above.
- **Rejected because**: cost + parallel-identity were both heavy enough that the ergonomic upside didn't compensate.

### Sidecar mode + SPIRE as external CA

- **Pros**: keeps SPIRE as the one identity universe; uses sidecar's mature feature set.
- **Cons**: still has per-pod resource cost; still has injection-into-operator-pods problems; the SPIRE-as-CA wiring is the same effort as Ambient.
- **Rejected because**: if we're going to do the SPIRE-CA wiring, we get more by also dropping sidecars.

### Linkerd

- **Pros**: lightweight; mTLS-by-default; simpler than Istio.
- **Cons**: SPIFFE-ID-based AuthorizationPolicy is less mature; external CA story is less developed; we'd be choosing a less common option without a strong reason.
- **Rejected because**: Istio's policy + ext-authz model is what we want, and Ambient solves the weight problem.

### Cilium service mesh

- **Pros**: kernel-level, very lightweight; one less process.
- **Cons**: requires Cilium as the cluster CNI (Docker Desktop ships with its own; would need to replace and is finicky); SPIFFE-ID integration story is younger.
- **Rejected because**: changing CNI on Docker Desktop is a stability risk we don't need.

### No mesh at all (just NetworkPolicy + app-layer mTLS)

- **Pros**: zero mesh overhead; we already have NetworkPolicies.
- **Cons**: every app would need to do its own mTLS; no consistent AuthorizationPolicy abstraction; observability hooks duplicated per-service.
- **Rejected because**: app-layer mTLS gets reinvented poorly in every service; the mesh is what enforces uniformity.

## Consequences

**Commits us to**:

- The cert-manager-csi-driver-spiffe component as a permanent dependency.
- Naming workload identities `spiffe://secforge.local/ns/{ns}/sa/{sa}` (already true for everything else).
- Deploying waypoint proxies wherever L7 policy is needed (incremental cost).
- Istio version ≥ 1.24, which is when Ambient + external-CA + csi-driver-spiffe got production-ready.

**Preserves**:

- The "SVID is the identity" invariant across OpenBao, SpiceDB, and the mesh.
- Same manifests work in cloud (only trust domain + SPIRE upstream CA change).
- Default-deny posture in the namespace where workloads run.

**New risks**:

- **Ambient is younger than sidecar.** Bug rate is higher; documentation for edge cases is thinner. Mitigated by pinning to a known-good Istio release and watching upstream issue trackers.
- **External-CA failures are now SPIRE failures.** If SPIRE is down, no new SVIDs issue, no new waypoints can come up. Mitigated by SPIRE's high availability story (single replica locally; multi-replica in cloud) and by the fact that issued SVIDs continue to work for their TTL even if the issuer is unreachable.
- **L7 features require waypoints**, which adds operational steps when introducing JWT-claim-based or path-based authz. Mitigated by deploying waypoints on demand and documenting the pattern.

## Re-evaluation criteria

Revisit if any of these change:

- Ambient hits a feature gap that costs more to work around than going to sidecar.
- A second mesh component (e.g., Cilium service mesh) matures and offers significant resource savings without giving up SPIFFE-ID policy.
- SPIRE itself is replaced or re-architected (e.g., merging into K8s control-plane).
- The platform expands to include workloads that explicitly cannot work with Ambient (e.g., raw-IP server protocols ztunnel doesn't yet support).

## References

- [Istio Ambient mesh announcement and architecture](https://istio.io/latest/blog/2022/introducing-ambient-mesh/)
- [Istio external CA via cert-manager-csi-driver-spiffe](https://cert-manager.io/docs/projects/csi-driver-spiffe/)
- [SPIRE Workload API spec](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Workload_API.md)
- [docs/01-architecture/07-service-mesh.md](../01-architecture/07-service-mesh.md)
- [docs/01-architecture/06-workload-identity.md](../01-architecture/06-workload-identity.md)
- [ADR-0005: SPIRE architecture (Local Edition)](./0005-spire-architecture-local.md)
