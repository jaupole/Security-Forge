# ADR-0035: Tailscale replaces Teleport for operator access

**Status**: Accepted
**Date**: 2026-06-07 (records a change made earlier; the deployment had already moved off Teleport)
**Decision-makers**: operator
**Supersedes**: [ADR-0024](./0024-teleport-community-edition-local.md)

## Context

ADR-0024 chose Teleport Community Edition as the privileged-access layer: OIDC-federated
`viewer`/`developer`/`admin` roles, kubectl and DB brokering, and per-session recording to MinIO.
It was deployed in the local edition (Phase 8a/8b). On the production single public Hetzner node the
design proved heavier than its value:

- Teleport needs its own Postgres backend, a MinIO bucket + scoped user, an OIDC connector wired to
  Keycloak, a public proxy hostname (`tp.secforge.dev`), a TLS cert, and an upgrade cadence — a
  whole control-plane component to maintain on a single-operator platform.
- Its main differentiators (centralized session recording, fine-grained brokered RBAC) matter most
  with many operators and many targets. Here there is one operator and one node.
- A public Teleport proxy is itself an internet-facing attack surface.

Meanwhile the host already needed an out-of-band, non-public administration path, and the platform
adopted **Tailscale** as the operator-access mesh (the host's public SSH was closed in favour of
tailnet-only `:22`).

## Decision

Stop running Teleport. Operator access is the **Tailscale tailnet**:

1. **Host / kubectl** — public SSH closed; the node is reachable only over the tailnet. Operator
   connects as the ops user (`ssh secforge`, dedicated key) and runs `sudo -n kubectl` on the box.
2. **Admin web surfaces** — operator/admin UIs (`control`, `admin`, `kc`, `bao`, `grafana`,
   `wazuh`, `pf`) are published only through the `secforge-gateway-tailnet` Istio gateway and
   resolve only from the tailnet. The split is enforced by the Kyverno
   `admin-ingress-must-be-tailnet-only` ClusterPolicy.

## Rationale

For a single-node, single-operator deployment, a tailnet provides the core need — strong, identity-
bound, non-public access to sensitive surfaces — with zero additional in-cluster control-plane
infrastructure and one fewer public attack surface. The lost capabilities (session recording,
brokered RBAC tiers) are acceptable for this scale, and host/cluster audit is still covered by
Wazuh (auditd + k3s audit + OpenBao/Keycloak decoders).

## Alternatives considered and rejected

- **Keep Teleport.** Rejected — operational weight and a public proxy surface not justified at this
  scale.
- **Bastion host + manual kubeconfig.** Rejected — more moving parts than a tailnet and weaker
  device identity.
- **Public k3s API with strong RBAC.** Rejected — exposes the API server to the internet; the
  tailnet keeps it off the public net entirely.

## Consequences

- No per-session kubectl/DB recording; audit relies on Wazuh and the host login-banner consent.
- Teleport's `teleport` namespace, CNPG `secforge-teleport-db`, MinIO `teleport-recordings` bucket
  and scoped user, Keycloak `teleport` client, and `tp.secforge.dev` ingress are decommissioned.
- Operator devices must be enrolled on the tailnet; losing tailnet access means falling back to a
  Hetzner hardware reset for out-of-band recovery.
- The architecture doc [01-architecture/09-privileged-access.md](../01-architecture/09-privileged-access.md)
  describes the current model.

## Re-evaluation criteria

Revisit if the platform gains multiple operators or many privileged targets, or if a compliance
requirement mandates tamper-evident per-session recording — at which point a brokered access layer
(Teleport or equivalent) with object-lock storage becomes worth its weight again.

## References

- [ADR-0024 — Teleport Community Edition (superseded)](./0024-teleport-community-edition-local.md)
- [01-architecture/09-privileged-access.md](../01-architecture/09-privileged-access.md)
