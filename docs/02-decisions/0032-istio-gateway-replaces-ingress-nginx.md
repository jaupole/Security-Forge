# ADR-0032: Istio ingress gateway replaces EOL ingress-nginx

- **Status:** Accepted — cutover completed 2026-06-03
- **Date:** 2026-06-03

## Context
`kubernetes/ingress-nginx` was archived 2026-03-24: no further releases, bug
fixes, or **security** patches. It fronted the entire public edge of this single
public node (10 hostnames / 8 backends). Running an EOL controller on the only
internet-facing component is an accumulating risk (future unpatched CVEs, e.g.
the already-public CVE-2026-4342 config-injection).

Options weighed:
- **Chainguard rebuild** (EmeritOSS) — a true drop-in, CVE-free, but a **paid**
  Production-tier image (`cgr.dev/<org>/...`, 403 anonymous). We use only the
  free Chainguard tier today, so it's net-new procurement.
- **Self-build** from the chainguard-forks fork — free but ongoing build/maintenance burden.
- **Migrate to the Istio gateway** — Istio already runs (ambient 1.29.2), so this
  *removes* a component rather than adding one, at no recurring cost. **Chosen.**

## Decision
Move ingress to a dedicated **Istio ingress gateway** (`istio-ingress` ns):
- **Native Istio `Gateway` + `VirtualService`** (Gateway-API CRDs not installed).
  TLS terminated with the single cert-manager **`*.secforge.dev` wildcard**
  (replaces 8 per-host certs). `:80`→`:443` redirect at the Gateway.
- **hostPort** (NOT hostNetwork — hostNetwork caused a hairpin bug for nginx).
  The `istio/gateway` chart has no hostPort value, so 06a patches the Deployment.
- **Edge authz via `AuthorizationPolicy` DENY + `notRemoteIpBlocks`** — the
  XFF-derived original client IP. `ipBlocks` (direct_remote_ip) does **not** see
  the real client behind hostPort; `remoteIpBlocks` is un-spoofable at the first
  hop (`numTrustedProxies=0`, verified). Replaces nginx `whitelist-source-range`.
  Covers: tailnet dashboards, the `auth` `/admin` split, the **billing Stripe-IP
  allowlist**, and the **portal `/api/v1/admin|system` deny-list** (the control
  API's only must-not-be-public prefixes; everything else is org-management).
- **Backend app-TLS** for keycloak/openbao via `DestinationRule` (SIMPLE,
  skip-verify); wazuh-dashboard is plain HTTP.
- **Global response headers** (X-Content-Type-Options, Referrer-Policy, HSTS)
  via a gateway `EnvoyFilter`; per-app CSP passes through.
- Proxy image **pinned by digest** (`sidecar.istio.io/proxyImage`); the two image
  Kyverno policies (08/09) set `autogen=pod-only` so the chart's `image: auto`
  Deployment template isn't the check point — the injected pod is.

The whole live state is reproducible from `platform/components/06a-istio-gateway.sh`
+ `platform/manifests/istio-gateway/` + `platform/values/istio-gateway.yaml`.

## Consequences / hard-won learnings
- **Kyverno reconciliations** (committed): `pss-baseline` host-ports exclusion for
  `istio-ingress`; `restrict-image-registries`/`require-image-digest` autogen→pod-only
  + digest-pinned proxy; a new istiod XDS/CA NetworkPolicy (the gateway is in its
  own ns, outside `allow-mesh-xds-to-istiod`).
- **AuthZ is host-scoped on `:authority`** → inert on the `:8443` staging port,
  enforces on `:443`. Validate externally post-cutover.
- **The cutover is delicate** (single-node `:80/:443` hand-off): nginx's 300s grace
  period, `--force` orphaning the CNI portmap DNAT (black-holes `:443`), and the
  node's inability to hairpin to its own public IP (false-negative tests). Full
  procedure: `docs/03-runbooks/ingress-nginx-to-istio-cutover.md`.
- **Backend mTLS DEFERRED:** enrolling the HTTP backends in ambient broke
  gateway→backend (503; gateway is non-ambient, the path needs convergence/HBONE
  netpol work). Un-enrolled — backends run plaintext-on-node = nginx parity (no
  regression). Re-enabling ambient mTLS is a tracked fast-follow.
- **`portal` is now public** (was tailnet) serving org-management; the control
  API's `/admin`+`/system` are blocked at the edge. `pf.secforge.dev` (Proposal
  Forge) is wired tailnet-only; its DNS A-record + OIDC client + base-URL are the
  app owner's to set.

## Decommission inventory (after ≥ a few days stable; nginx kept scaled-0 for rollback)
- `helm uninstall ingress-nginx` (controller, admission webhook, RBAC, `nginx`
  IngressClass).
- The 10 Ingress objects (app-owned: delete object + manifest; helm-owned
  `wazuh-dashboard`: set `ingress.enabled=false`).
- Redundant per-host certs: control/billing/qbo/keycloak/members/grafana/
  openbao-public/wazuh-dashboard `-tls` (⚠ keep `keycloak-internal-tls`).
- `secforge-default-headers` ConfigMap; the ingress-nginx egress NetworkPolicy.
- Repo: `00c-ingress-nginx.sh`, `10a-ingress-tailnet-split.sh`,
  `values/ingress-nginx.yaml`, `manifests/ingress-nginx/`; drop them from
  `install-all.sh`.
- **Retarget** (not delete) Kyverno `admin-ingress-must-be-tailnet-only` from
  Ingress to require a tailnet `AuthorizationPolicy` for admin-shaped hosts.
