# ADR-0005: SPIRE Architecture (Local Edition)

**Status**: Accepted
**Date**: 2026-04-29
**Decision-makers**: Project owner

> The README.md ADR index reserves "0003 SPIRE trust domain naming." That slot was used by `0003-cloudnativepg-vs-others.md`; this ADR (0005) replaces both the originally reserved 0003 and any prior intent to record the SPIRE trust-domain decision. There are no other ADRs about SPIRE; this one is canonical.

## Context

Phase 2 of the Local Edition build deploys SPIRE so every workload in the cluster has a cryptographic identity (SPIFFE ID) that can be used for mTLS, JWT-bearer authentication to OpenBao, and authorization-policy gating in Istio. SPIRE will run on Docker Desktop's single-node Kubernetes. There is no cloud KMS, no AWS IAM, no managed Postgres, no second cluster to federate with.

We need to decide:

1. The trust-domain name.
2. Where the upstream signing CA lives, given that no cloud KMS is available.
3. How node identity is attested.
4. How workload registrations are managed (manual entries vs. CRD-based).
5. Datastore for the spire-server.
6. Defaults for SVID TTL and the identity opt-in mechanism.

Each of these has a defensible cloud answer; the question is what the *local* answer should be while preserving a clean migration path.

## Decision

We adopt the following architecture for the Local Edition. Each item names the local choice and the cloud equivalent it's replacing, so the migration path is explicit.

| Concern | Local choice | Cloud equivalent |
|---|---|---|
| Trust domain | `spiffe://secforge.local` | `spiffe://{env}.secforge.internal` per environment |
| Upstream CA | `disk` plugin reading an Ed25519 key + self-signed root cert from a K8s Secret mounted only into spire-server | `aws_kms` / `gcp_cloudkms` / `azure_keyvault` UpstreamAuthority plugin |
| CA generation | `openssl ecparam -name prime256v1 -genkey -noout` once; X.509 self-signed cert; key+cert imported as Secret with keys `tls.crt` / `tls.key`; local copies shredded | KMS key created via cloud IaC; never touches local disk |
| Datastore | SQLite on a PVC (single replica, no HA) | Postgres (RDS) with a multi-AZ deployment |
| Node attestor | `k8s_psat` (Projected Service Account Token) | `aws_iid` / `gcp_iit` / `azure_msi` *plus* `k8s_psat` |
| Workload attestor | `k8s` + `unix` | Same |
| Registration | `ClusterSPIFFEID` CRDs reconciled by spire-controller-manager | Same |
| SVID delivery | spire-spiffe-csi-driver volume in workload pods | Same |
| X.509-SVID TTL | 1 hour | Same |
| JWT-SVID TTL | 5 minutes | Same |
| Identity opt-in | Label `spiffe.io/spire-managed-identity: "true"` (default), or namespace-scoped registration for platform namespaces | Same |
| Helm chart | `spiffe/spire` umbrella chart, version 0.28.4 (SPIRE 1.14.5), `spiffe/spire-crds` 0.5.0 | Same chart, possibly newer version |

## Rationale

### Trust domain: `spiffe://secforge.local`

Matches the local DNS suffix (`*.secforge.local`). Distinct from the cloud trust domains we will use for `dev`/`staging`/`prod` (`*.secforge.internal`), so there is no risk of an SVID issued in local being confused for a real-environment SVID. The trust-domain re-bootstrap at cloud-migration time is intentional: we do **not** want SVIDs from a developer laptop to ever validate against a production trust bundle.

### Upstream CA: `disk` plugin reading from a K8s Secret

The cloud edition uses a KMS-backed root because that is the only way to keep the root key off any disk anyone can read. Locally we have no KMS. The least-bad alternative is:

1. Generate the root key once with `openssl`, locally.
2. Import it as a Kubernetes Secret in the `spire` namespace.
3. Restrict `get` on that Secret to the spire-server ServiceAccount only.
4. Mount it into spire-server with `defaultMode: 0400`.
5. Shred the original local copies of the key and cert.

This is not as good as a KMS — a Kubernetes Secret is base64, not encrypted — but it confines the key to the cluster, isolates access via RBAC, and ensures it never re-appears on developer disk. The CA private key is Ed25519 (modern, fast, standard) with a 10-year validity; rotation procedure is in [docs/03-runbooks/spire-ca-rotation.md](../03-runbooks/spire-ca-rotation.md).

Rejected alternatives:

- **mkcert as the SPIRE upstream**: mkcert's CA is shared with cert-manager for ingress TLS. Reusing it for SPIRE would conflate the "TLS certs anyone in the cluster might receive" trust anchor with the "workload identity" trust anchor. They should be distinct CAs because they have different rotation cadences, different blast radius, and different consumers. mkcert stays for ingress-nginx + cert-manager only.
- **Self-signed CA inside SPIRE (no UpstreamAuthority)**: simplest, but the bundle changes every time spire-server reboots from scratch. Anything caching a trust bundle (Istio, OpenBao) would have to re-trust on every reset. The `disk` upstream gives us a stable root that survives spire-server rebuilds.
- **Local OpenBao Transit as upstream (UpstreamAuthority `vault` plugin)**: OpenBao isn't deployed yet (Phase 5). Even after it's up, it creates a circular dependency — OpenBao authenticates workloads via JWT-SVID, which requires SPIRE, which would in turn rely on OpenBao for upstream signing. Rejected on dependency grounds.

### Datastore: SQLite

Single-node Docker Desktop. No HA story is meaningful here. SQLite removes the dependency on a Postgres cluster and lets spire-server start cleanly on a fresh `helm install` without coordinating with cloudnative-pg. Migration to Postgres at cloud time is a config change, not a re-architecting.

### Node attestor: `k8s_psat`

`k8s_psat` works on every Kubernetes distribution that supports projected service account tokens — which includes Docker Desktop K8s. There is no `aws_iid` analog locally because there is no EC2 metadata service. PSAT is the right local choice, and the cloud edition layers `aws_iid` on top of (not instead of) PSAT for additional attestation signal.

### Registrations as `ClusterSPIFFEID` CRDs

The alternative — managing entries via `spire-server entry create` calls — is imperative, error-prone, and not Git-friendly. CRDs reconciled by spire-controller-manager are declarative and version-controlled. Standard practice in the SPIRE community.

### Identity opt-in via label

We considered making "every pod gets an identity" the default. Rejected: it gives identities to system pods, kube-proxy daemonsets, etc., that don't need them, and it makes the security-relevant question "what gets a SPIFFE ID?" answerable only by enumerating cluster contents. The label-based opt-in (Pattern 1) is the safe default. For namespaces we control end-to-end (`keycloak`, `spicedb`, `openbao`, `app`, `istio-system`), we add a namespace-scoped registration (Pattern 2) so platform pods don't need to remember the label — but the rule is still explicit and lives in source control.

### TTLs: 1h X.509 / 5m JWT

These are the SPIRE community defaults. Short enough that revocation latency is bounded by rotation; long enough that the agent isn't hammering the server. We do not deviate.

## Alternatives considered and rejected

### Skip SPIRE locally; use plain ServiceAccount tokens

Service account tokens authenticate to the Kubernetes API but not to OpenBao, SpiceDB, or app-to-app calls. They are also long-lived by default. Skipping SPIRE would defer building the workload-identity muscle memory until cloud migration, at which point the platform's authorization model would change shape and break apps that were built against ServiceAccount-token assumptions. Rejected.

### Use cert-manager + mkcert for workload mTLS instead of SPIRE

cert-manager issues certs based on `Certificate` resources; it doesn't attest the requesting workload. Anyone with `create` rights on `Certificate` could request a cert with whatever CN they wanted. SPIRE attests the workload before issuing. They serve different purposes; cert-manager stays for ingress and cert-manager stays out of workload identity. Rejected.

### Run SPIRE in nested mode (one root server + downstream agents)

The nested topology (`spiffe/spire-nested` chart) is for very large environments where a single SPIRE server can't keep up. Single Docker Desktop node, low pod count — flat is correct. Rejected.

## Consequences

### What this commits us to

- A 10-year-validity root CA stored as a K8s Secret. Document a rotation runbook now even though we won't use it for years.
- A label-based opt-in convention (`spiffe.io/spire-managed-identity: "true"`) every workload deployment must remember to set, *unless* the workload lives in one of the namespaces with a namespace-scoped registration.
- spire-controller-manager as a dependency for declarative registrations.
- An expectation that workloads use the SPIFFE Workload API via `go-spiffe/v2` (Go) or equivalent SPIFFE libraries in other languages — not raw access to SVID files.

### What this preserves

- The SPIFFE ID structure (`spiffe://{trust-domain}/ns/{ns}/sa/{sa}`) is identical to what we'll use in cloud. Workloads do not change at migration time.
- The label / namespace registration model is identical.
- The CSI driver mount path is identical.
- Helm chart and values structure is identical; only the upstream-authority section changes.

### Known gaps in the local edition

1. **Root key on Kubernetes Secret base64.** Acceptable locally; not acceptable in production. KMS at cloud-migration.
2. **No HA.** Single spire-server replica with SQLite. If it crashes, there is a brief window where new pods can't get SVIDs (existing pods continue with their cached SVIDs until rotation).
3. **No cloud trust-domain federation.** SPIRE can federate but there is no second trust domain to federate with locally.
4. **Audit log goes to STDOUT only** until Phase 7 deploys Loki/Wazuh.

## Re-evaluation criteria

Re-open this ADR if:

- The SQLite datastore becomes a bottleneck (would surprise me, but plausible if we end up with hundreds of registrations).
- We decide to develop multi-cluster or multi-trust-domain features locally and need federation.
- A new SPIRE major version changes the recommended attestor or storage defaults significantly.

## References

- [docs/01-architecture/06-workload-identity.md](../01-architecture/06-workload-identity.md) — architecture as deployed.
- [docs/03-runbooks/spire-ca-rotation.md](../03-runbooks/spire-ca-rotation.md) — upstream CA rotation procedure.
- [docs/03-runbooks/spire-rotation.md](../03-runbooks/spire-rotation.md) — operational rotation and recovery.
- [docs/06-reference/spiffe-ids.md](../06-reference/spiffe-ids.md) — SPIFFE ID naming reference.
- [docs/06-reference/spire-openbao-pattern.md](../06-reference/spire-openbao-pattern.md) — JWT-SVID auth pattern for OpenBao (deferred to Phase 5).
- SPIRE upstream: <https://spiffe.io/docs/latest/spire-about/>
- Helm chart: <https://github.com/spiffe/helm-charts-hardened>
