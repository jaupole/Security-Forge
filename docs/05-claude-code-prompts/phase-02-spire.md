# Phase 2 — Workload Identity (SPIRE)

**Status:** ⬜ Not started · ⬜ In progress · ⬜ Complete

**Estimated time:** 1-2 days

**Prerequisites:** Phase 1 complete.

---

## Goal of this phase

Deploy SPIRE so every pod and service in the local cluster gets an automatic, attested cryptographic identity. Trust domain: `spiffe://secforge.local`.

---

## What you (the human) need to do first

1. Confirm Phase 1 is complete — `spire` namespace exists.
2. Read the "Workload identity: SPIRE" section of `docs/01-architecture/00-overview.md`.

---

## Prompt for Claude Code

> Copy everything between the lines below into Claude Code.

---

```
We're starting Phase 2 of the SecForge Local Edition platform build. Read CLAUDE.md, PLAN.md, and docs/05-claude-code-prompts/phase-02-spire.md before doing anything.

Your task is to deploy SPIRE in the local Docker Desktop cluster. No cloud federation (we don't have AWS to federate to). Trust domain `spiffe://secforge.local`.

## Phase 2.1 — Design

Document in docs/01-architecture/06-workload-identity.md and docs/02-decisions/0002-spire-architecture-local.md:

- Trust domain: spiffe://secforge.local
- Upstream authority: file-based root key + cert (the local equivalent of cloud KMS). Generate with openssl. Store private key as a Kubernetes Secret in `spire` namespace, mounted only into the spire-server pod.
- Datastore: SQLite for local (single-replica, no HA)
- Node attestor: k8s_psat (Projected Service Account Token — works on any K8s including Docker Desktop)
- Workload attestor: k8s + unix
- Registration: ClusterSPIFFEID CRDs via spire-controller-manager

Local-specific note: no aws_iid attestor (no EC2 here). PSAT is the right choice.

## Phase 2.2 — Generate root CA materials

Generate the upstream CA:
```bash
mkdir -p /tmp/spire-ca
cd /tmp/spire-ca

# Root CA private key
openssl genpkey -algorithm Ed25519 -out root-ca.key

# Root CA self-signed cert
openssl req -new -x509 -days 3650 -key root-ca.key \
  -subj "/CN=SecForge Local SPIRE Root CA" \
  -out root-ca.crt
```

Create a Kubernetes Secret in `spire` namespace from these:
```bash
kubectl create secret generic spire-upstream-ca \
  --namespace=spire \
  --from-file=root-ca.key=root-ca.key \
  --from-file=root-ca.crt=root-ca.crt
```

Then SHRED the private key file:
```bash
shred -u /tmp/spire-ca/root-ca.key
rm /tmp/spire-ca/root-ca.crt
```

Document this in docs/03-runbooks/spire-ca-rotation.md — when this CA expires (10 years), here's how to rotate.

## Phase 2.3 — Deploy SPIRE

Use the official spiffe Helm chart (`spiffe.io/charts`):
- spire-server: 1 replica, SQLite, upstream authority = file plugin reading from `/run/spire/upstream/`
- Mount the `spire-upstream-ca` secret at `/run/spire/upstream/`
- spire-agent: DaemonSet (1 pod on the single node)
- spire-controller-manager: enables ClusterSPIFFEID resources
- spire-spiffe-csi-driver: lets pods mount SVID material as a volume
- Trust domain: `secforge.local`

Show me the values file before applying.

## Phase 2.4 — Configure registration

Create initial ClusterSPIFFEID resources for the namespaces we'll need:

A "default" entry that gives any pod a SPIFFE ID derived from its service account:
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: default
spec:
  spiffeIDTemplate: "spiffe://secforge.local/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      spiffe.io/spire-managed-identity: "true"
  ttl: 1h
```

Pods that should get an identity must include the label `spiffe.io/spire-managed-identity: true`.

For namespaces that ALL pods should get identity in (keycloak, spicedb, openbao, app, istio-system), create namespace-level entries with namespace selectors instead of label selectors.

## Phase 2.5 — Test workload identity

Deploy a small test pod in `test-spire` namespace (create it):
- ServiceAccount `test-app`
- Pod with label `spiffe.io/spire-managed-identity: true`
- Mount the SPIFFE CSI driver volume
- Container is a tiny Go program (write it) that:
  1. Reads the X.509-SVID from the CSI mount
  2. Prints the SPIFFE ID, NotBefore, NotAfter
  3. Calls the SPIFFE Workload API socket to fetch a JWT-SVID for audience "test-audience"
  4. Prints the JWT
  5. Sleeps 30 seconds (so we can re-check rotation)
  6. Exits

Verify:
- The pod's SPIFFE ID matches expected: `spiffe://secforge.local/ns/test-spire/sa/test-app`
- The X.509-SVID is signed by the upstream root CA (verify chain)
- The JWT-SVID can be obtained
- After waiting 30+ minutes (TTL = 1h, rotation at 50%), a fresh SVID is issued (you can verify by viewing the CSI volume contents over time)

## Phase 2.6 — OpenBao integration prep (deferred)

Document in docs/06-reference/spire-openbao-pattern.md the pattern that workloads will use to authenticate to OpenBao:
- Pod fetches JWT-SVID from SPIRE (audience = "openbao")
- POSTs to OpenBao's JWT auth endpoint
- OpenBao verifies the JWT-SVID against SPIRE's JWKS
- OpenBao issues a token bound to a role tied to that SPIFFE ID

We'll wire this up in Phase 5. For now, just confirm SPIRE is exposing JWKS at the expected endpoint.

## Phase 2.7 — Verify hardening

Verify:
- spire-server has minimum RBAC (only what's needed for k8s_psat attestor)
- spire-agent has the minimum host mounts
- Upstream CA private key is in a Secret only mounted into spire-server, with restricted file permissions inside the pod
- SVID TTLs are short (1h)
- Audit logs from spire-server are emitted as structured JSON to STDOUT

## Phase 2.8 — Documentation

Update:
- docs/01-architecture/06-workload-identity.md (architecture as deployed)
- docs/03-runbooks/spire-rotation.md (how to rotate the upstream CA, how to recover from corruption)
- docs/02-decisions/0002-spire-architecture-local.md
- docs/06-reference/spiffe-ids.md (the canonical SPIFFE ID naming scheme)

## Constraints

- Upstream CA private key MUST be in a Secret with restricted access, never on host disk
- spire-agent MUST run as non-root
- No SPIFFE ID may be `*`-wildcarded in registrations
- TTLs ≤ 1 hour for SVIDs
- Workloads must opt-in via the `spiffe.io/spire-managed-identity` label
```

---

## Success criteria

- [ ] SPIRE server and agent deployed and healthy
- [ ] Upstream CA materials in a Secret, restricted access
- [ ] Test workload successfully fetches X.509-SVID and JWT-SVID
- [ ] SPIFFE ID matches expected naming convention
- [ ] SVIDs rotate before expiry
- [ ] Documentation updated
- [ ] PLAN.md updated

---

## Troubleshooting

### "spire-agent can't attest the workload"
Check that the pod has the `spiffe.io/spire-managed-identity: true` label, the right service account exists, and the namespace is registered. `kubectl logs -n spire ds/spire-agent` shows attestation attempts.

### "JWT-SVID validation fails downstream"
The audience claim must match exactly. The receiver must be able to fetch SPIRE's JWKS (which is at the spire-server bundle endpoint).

### "SVIDs aren't rotating"
Check the TTL settings and that the agent has fresh upstream bundle data. Force a rotation by restarting spire-agent.

---

## What's next

[Phase 3 — Identity Provider (Keycloak)](./phase-03-keycloak.md).
