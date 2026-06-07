# SPIFFE ID Naming Reference

**Trust domain (Local Edition):** `spiffe://secforge.platform`

This document is the canonical naming scheme for SPIFFE IDs in this platform. Every workload that gets a SPIFFE ID gets one that conforms to one of the patterns below. New patterns require an ADR.

## Default pattern: namespace + service account

```
spiffe://secforge.platform/ns/{namespace}/sa/{serviceaccount}
```

This is what the `default` `ClusterSPIFFEID` registration produces, and what every label-opted-in or namespace-scoped pod gets. It maps directly to the Kubernetes attestation surface, so the SPIFFE ID cannot lie about which namespace and SA it came from.

## Reserved IDs across the platform

| Component | SPIFFE ID |
|---|---|
| BFF | `spiffe://secforge.platform/ns/app/sa/bff` |
| Hello-world API | `spiffe://secforge.platform/ns/app/sa/api` |
| Keycloak | `spiffe://secforge.platform/ns/keycloak/sa/keycloak` |
| Keycloak operator | `spiffe://secforge.platform/ns/keycloak/sa/keycloak-operator` |
| SpiceDB | `spiffe://secforge.platform/ns/spicedb/sa/spicedb` |
| AuthZEN façade | `spiffe://secforge.platform/ns/spicedb/sa/authzen` |
| OpenBao | `spiffe://secforge.platform/ns/openbao/sa/openbao` |
| Istio control plane | `spiffe://secforge.platform/ns/istio-system/sa/istiod` |
| Istio gateway | `spiffe://secforge.platform/ns/istio-system/sa/istio-ingressgateway` |
| ztunnel | `spiffe://secforge.platform/ns/istio-system/sa/ztunnel` |
| Test workload (Phase 2.5) | `spiffe://secforge.platform/ns/test-spire/sa/test-app` |

When you add a workload, decide its service account name and add a row here. Conflict-resolution rule: one service account per workload identity. If two workloads need to talk in different roles (e.g., one for outbound traffic, one for admin actions), they get two ServiceAccounts and two SPIFFE IDs.

## Sub-identity pattern (rare, requires ADR)

If a single workload genuinely needs to present multiple personas — e.g., one identity for tenant-scoped operations and one for platform-scoped ones — you may extend the path:

```
spiffe://secforge.platform/ns/{namespace}/sa/{serviceaccount}/component/{name}
```

This is reserved for cases where splitting the workload into two pods is impractical. Document the rationale in an ADR before using it. As of this writing, no workload uses this pattern.

## Forbidden patterns

- ❌ `spiffe://secforge.platform/*` or any wildcard. SPIRE permits it; we don't. Every registration must be exact.
- ❌ Putting a username, customer name, or any human PII into the path. The SPIFFE ID identifies *workloads*, not end users. End-user identity lives in OAuth tokens / OIDC claims.
- ❌ Reusing a SPIFFE ID across trust domains. When we move to cloud, every environment gets its own trust domain (`spiffe://dev.secforge.internal`, `spiffe://prod.secforge.internal`); the path inside is the same, but the trust domain is different.

## How to add a new workload identity

1. Pick (or create) a Kubernetes ServiceAccount in the workload's namespace.
2. Decide whether the workload's namespace is one with a namespace-scoped registration (Pattern 2 in [docs/01-architecture/06-workload-identity.md](../01-architecture/06-workload-identity.md)) — `keycloak`, `spicedb`, `openbao`, `app`, `istio-system`. If so, no further registration is needed; the workload just needs to mount the CSI volume.
3. Otherwise, label the pod template with `spiffe.io/spire-managed-identity: "true"` to opt into the default registration.
4. Add a row to the table above for the new SPIFFE ID.
5. If the workload needs a JWT-SVID with a specific audience (e.g., `openbao`), add the audience to the appropriate `ClusterSPIFFEID` `jwtIssuer`/`jwtAudiences` configuration.

## Verification

You can ask SPIRE for the registrations it has:

```bash
kubectl exec -n spire statefulset/spire-server -- \
  /opt/spire/bin/spire-server entry show
```

And ask any pod what its identity is, given it has the CSI mount:

```bash
kubectl exec -n {ns} {pod} -- \
  /opt/spiffe-helper/spiffe-helper -socketPath /spiffe-workload-api/spire-agent.sock
```
