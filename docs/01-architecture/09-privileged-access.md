# Privileged Access

> Decision records: [ADR-0035 — Tailscale replaces Teleport for operator access](../02-decisions/0035-tailscale-replaces-teleport.md) (current) · [ADR-0024 — Teleport Community Edition](../02-decisions/0024-teleport-community-edition-local.md) (superseded).

Operator access to the platform's sensitive surfaces runs over a **Tailscale** tailnet. Teleport
was evaluated (ADR-0024) and **stopped** (ADR-0035) — there is no Teleport in production.

## Model

Two layers, both gated on the operator's Tailscale identity:

1. **Host / kubectl access.** Public SSH (`:22`) is closed to the internet; the host is reachable
   only over the tailnet. The operator connects as the ops user (`ssh secforge`, dedicated
   `hetzner_secforge` key) and runs `sudo -n kubectl` on the node against the local k3s
   kubeconfig. There is no public Kubernetes API endpoint.
2. **Admin web surfaces.** Operator/admin web UIs are published only through the
   `secforge-gateway-tailnet` Istio gateway and resolve only from the tailnet. Public app
   surfaces go through the separate public `secforge-gateway`.

The split is enforced in admission control by the Kyverno **`admin-ingress-must-be-tailnet-only`**
ClusterPolicy: a `VirtualService` that binds an admin host to the public gateway is rejected.

## Surface map

| Host | Surface | Gateway |
|---|---|---|
| `control.secforge.dev` / `admin.secforge.dev` | Operator / admin shell (Ecosystem Control) | **tailnet-only** |
| `kc.secforge.dev` | Keycloak admin console | **tailnet-only** |
| `bao.secforge.dev` | OpenBao | **tailnet-only** |
| `grafana.secforge.dev` | Grafana | **tailnet-only** |
| `wazuh.secforge.dev` | Wazuh dashboard | **tailnet-only** |
| `pf.secforge.dev` | Proposal Forge | **tailnet-only** |
| `auth` / `portal` / `members` / `billing` / `qbo` / `stripe-connect`.secforge.dev | Public app surfaces | public |

## Authentication & identity

- Tailnet membership is the operator's Tailscale identity; devices must be enrolled and authorized
  on the tailnet before any admin surface is reachable.
- Host SSH is key-based (`hetzner_secforge`), no password. `tailscale ssh` is not used and the WSL
  key does not work — connect with the dedicated key as the ops user.
- The Keycloak master-realm admin (`jaupole`) is WebAuthn-required and **DB-only** (no password on
  the box); scripted Keycloak changes go via direct Postgres writes, not `kcadm`/admin-API. The
  admin console at `kc.secforge.dev` is itself tailnet-only. See
  [keycloak-operations.md](../03-runbooks/keycloak-operations.md).

## Trade-offs vs. the Teleport design

The earlier design (ADR-0024) centralized privileged access through Teleport — OIDC-federated
`viewer`/`developer`/`admin` roles and per-session recording to a MinIO bucket. It was stopped
(ADR-0035): for a single-node, single-operator platform the operational weight of Teleport (its own
Postgres backend, MinIO bucket, OIDC connector, public proxy, cert, and upgrade cadence) outweighed
the benefit.

- **Lost:** per-session `kubectl exec` / DB session *recording* and Teleport's fine-grained RBAC
  roles.
- **Gained:** no extra control-plane infrastructure; access control is the tailnet + host SSH +
  k3s RBAC; one fewer internet-facing attack surface (no Teleport proxy on the public internet).
- **Audit:** host and cluster activity is captured by **Wazuh** (auditd + k3s audit + OpenBao /
  Keycloak decoders), not Teleport recordings. The host login banner records consent-to-monitor.

## Recovery note

"SSH refused" does **not** mean the box is down — check the tailnet first (`tailscale ping`). The
host is reachable only over the tailnet; a Hetzner hardware reset is the only out-of-band path. See
[operator-cheatsheet.md](../06-reference/operator-cheatsheet.md).
