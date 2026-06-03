# istio-ingress — two-plane ingress (public NIC vs tailnet NIC)

Established 2026-06-03. This directory codifies the **tailnet plane** of a
two-gateway split. The pre-existing public gateway + Gateway CR + most
VirtualServices were created out-of-band (Helm + `kubectl`, never committed);
the imperative changes that turned them into the "public plane" are recorded
below so the whole setup is reconstructible.

## The problem this solves

`pf.${DOMAIN}` and all admin dashboards were reachable **from the public
internet**. The Istio ingress gateway (`istio-ingress`) binds `hostPort 80/443`
on `0.0.0.0` (every NIC, including the node's public IP `65.21.25.40`). The
tailnet-only restriction was attempted with `DENY` AuthorizationPolicies using
`notRemoteIpBlocks` (source-IP allowlists) — but **they don't work here**:

> The CNI hostPort path SNATs every inbound request to the cni0 bridge IP
> `10.42.0.1` **before Envoy sees it** (confirmed in the gateway access log:
> `downstream_remote_address` / `x_forwarded_for` = `10.42.0.1` for real
> browser traffic). The real client IP is gone, so a source-IP policy cannot
> tell a tailnet client from the public internet. Policies that allow
> `10.42.0.0/16` therefore allow *everyone*; `pf-tailnet` only "worked" by
> accidentally omitting `10.42.x` (which blocked everyone, including the
> operator).

## The fix: L3 separation by NIC

Two gateway pods, each binding `hostPort 443` to a **specific** `hostIP`:

| Plane | Gateway | hostIP | Hosts |
|---|---|---|---|
| **Public** | `istio-ingress` (existing) | `65.21.25.40` | `portal`, `auth`, `members`, `qbo`, `billing` |
| **Tailnet** | `istio-ingress-tailnet` (this dir) | `100.77.117.112` | `pf`, `control`, `admin`, `grafana`, `bao`, `wazuh` |

A request to the public IP for a tailnet host never reaches the tailnet
listener (it isn't bound there), so the public gateway has no route for it and
returns 404. Enforcement is L3 (NIC binding), independent of the lost client IP.

Verified: every tailnet host returns the app on `100.77.117.112` and **404 on
`65.21.25.40`**; every public host serves on `65.21.25.40`.

## Imperative changes applied to the (un-codified) public plane

These were `kubectl patch`/`delete` against live objects — re-apply if the
public gateway is ever recreated from its Helm source:

1. **Public gateway hostPort → public NIC only.** Patched `deploy/istio-ingress`:
   `strategy.type: Recreate` (hostPort can't surge) and added
   `hostIP: 65.21.25.40` to container ports `http` (80) and `https` (443).
2. **Tailnet VirtualServices moved.** `proposal-forge`, `grafana`, `openbao`,
   `wazuh` had `.spec.gateways` repointed from `istio-ingress/secforge-gateway`
   to `istio-ingress/secforge-gateway-tailnet`.
3. **`control-portal` VS split.** Reduced to `hosts: [portal.${DOMAIN}]` (public);
   `control`+`admin` moved to `control-admin-tailnet` (in `10-tailnet-gateway.yaml`).
4. **Deleted dead policies.** `pf-tailnet` and `tailnet-dashboards`
   AuthorizationPolicies removed (non-functional source-IP denies for hosts that
   are now L3-isolated).

## Known follow-ups (not yet done)

- **`auth-admin-tailnet` / `billing-allowlist` policies remain** but are
  non-functional (same SNAT issue — they allow all real traffic via `10.42.0.1`).
  - Keycloak `/admin` is therefore still reachable on the public `auth` host.
    Proper fix: an L7 path-DENY on `/admin*` at the public gateway (Envoy *can*
    enforce host+path), or move Keycloak admin to a tailnet host. Keycloak's own
    auth still gates it.
  - Billing webhook security is **Stripe signature verification** (done in-app),
    not the IP allowlist. True IP-allowlisting needs client-IP preservation
    (not possible with the current hostPort+SNAT path).
- **Public gateway is still Helm/un-codified.** Fully codify `deploy/istio-ingress`,
  `svc`, `gateway/secforge-gateway`, and the remaining VirtualServices.
- `100.77.117.112` / `65.21.25.40` are node-specific literals (ideally → globals.env).

## Apply

`platform/manifests/**` use `${DOMAIN}` placeholders — apply via
`platform/lib/apply-manifest.sh` (envsubst), never raw `kubectl apply -f`.
