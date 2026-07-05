# onlyoffice (ONLYOFFICE Docs — Document Server)

The fleet's shared **document editor + conversion service** (DOCENG Phase 1 of
the PF Document Engine program). It serves the browser editor (`api.js` +
WebSocket co-editing), the ConvertService (DOCX⇄PDF etc.), and the command
API, all behind nginx on `:80`. Documents do **not** live here — they transit;
Proposal Forge's MinIO is the store.

Pattern sibling: `../document-render/` (Gotenberg). The ONE fundamental
difference: **browsers must reach the DS** (the editor iframe talks to it
directly), so unlike Gotenberg it has an Istio gateway host —
`docs.${DOMAIN}`, routed in `../istio-ingress/20-virtualservices.yaml`.

## Consumers

| App | Status | Calls |
|---|---|---|
| Proposal Forge | Phase 1 (this change) | `http://onlyoffice.onlyoffice.svc.cluster.local:80` (server-side) + `https://docs.${DOMAIN}` (browser editor) |
| Ecosystem Control | Planned (usage-monitor command-service polling) | same |

When a new consumer comes online you must, in this namespace:
1. add its namespace to `allow-ingress-from-consumers` (05-network-policies.yaml),
2. add its SPIFFE principal to `allow-consumers-to-onlyoffice` (06-authorization-policy.yaml),
3. if the DS must fetch documents from / post callbacks to it, add an
   `allow-egress-to-<app>` here (mirror of `allow-egress-to-proposal-forge`),
and in the consumer's namespace: an `allow-egress-to-onlyoffice` +
`allow-ingress-from-onlyoffice` NetworkPolicy pair and a VaultStaticSecret
syncing `secret/apps/onlyoffice/jwt` (see proposal-forge for both).

## Licensing note

Pinned to **9.4.x Community** — 9.4 removed the Community Edition connection
limit entirely, so there is no 20-connection ceiling to engineer around.
Community has no license key; **JWT is therefore the only application-layer
auth the DS has**. `JWT_ENABLED=true` is mandatory, always — never deploy this
service with JWT off.

## Security posture (deviations are deliberate)

- **Runs as root / PSS `baseline`** — the AIO vendor image runs nginx +
  embedded postgres + rabbitmq + Node services under supervisord as root
  (services drop privileges themselves). PSS `restricted` rejects it, so the
  namespace is `baseline` (01-namespace.yaml) and `onlyoffice` is a documented
  exemption in `kyverno/policies/06-require-runasnonroot.yaml`.
- **Zero internet egress** — NetworkPolicy allows DNS + proposal-forge:3001
  only (05-network-policies.yaml). Fonts are baked into the image; documents
  come from PF's one-time URLs only. This is the primary SSRF containment for
  the DS's document-fetch path.
- **Fleet-shared JWT secret** — the DS has ONE global JWT secret, held at
  OpenBao `secret/apps/onlyoffice/jwt` and VSO-synced into this namespace AND
  each consumer namespace. Rotate once in OpenBao; every sync follows.
- **`/example` denied at the gateway** — the DS ships an example/test app;
  the VirtualService answers `/example*` with a 404 directResponse.
- **L4-only AuthorizationPolicy** — no waypoint, so principals + port 80 only
  (06-authorization-policy.yaml).

## Image

`ghcr.io/jaupole/onlyoffice-documentserver:9.4.0.1-secforge` is a **thin
signed build** over `docker.io/onlyoffice/documentserver:9.4.0.1` (upstream
pinned by digest in `image/Dockerfile`, Ubuntu base apt-upgraded at build
time). It exists because Kyverno's registry allowlist has no
docker.io/onlyoffice entry — ghcr.io/jaupole/* + cosign keyless is the
approved chain. Built by `.github/workflows/onlyoffice-image-build.yml`
(build → Trivy **report-only** for the vendor AIO base → cosign sign → digest
in the job summary). Set the GHCR package **public** after the first run; pin
`09-deployment.yaml` to the printed digest.

## Built-in editor plugins (Proposal Forge)

Proposal Forge embeds two editor-panel plugins — **Proposal Fields** (insert
`{{slug}}` placeholders) and **Boilerplate Library** (insert reusable org
boilerplate). They are **built into this image** under
`/var/www/onlyoffice/documentserver/sdkjs-plugins/{pf-fields,pf-library}/`
(`image/Dockerfile` COPYs them from `image/plugins/`, a **vendored copy** of
PF's `client/public/plugins/` — source of truth is the PF repo; keep in sync).

The DS auto-discovers any folder under `sdkjs-plugins/`
(`services.CoAuthoring.plugins.uri = "/sdkjs-plugins"`) and serves it
same-origin, so the editor loads them without the per-session
`editorConfig.plugins.pluginsData` manifest fetch that was **not** loading them
on 9.4. PF drives them per session from its signed editor-config:
`plugins.autostart:[<guid>,<guid>]` + a per-GUID `plugins.options:{<guid>:{ctx,api}}`
carrying a short-lived token. The plugin reads that at `Asc.plugin.info.options`
and fetches its data from PF cross-origin (the
`/api/v1/onlyoffice/{fields,library}/:token` endpoints, CORS-pinned to this DS's
public origin — which is exactly the built-in plugin frame's own origin).

### Marketplace store is NOT disabled at the server (deliberate)

There is **no Document Server config key** to disable only the
onlyoffice.github.io plugin **marketplace/store** on 9.4:
`services.CoAuthoring.plugins` exposes only `uri`/`autostart`/`pluginsData`, and
`editorConfig.customization.plugins:false` would disable **all** plugins —
including the two built-ins above (upstream **ONLYOFFICE/DocumentServer#2118** is
open). We therefore do **not** mount a `local.json` overlay: the vendor image's
entrypoint generates `local.json` from env (`JWT_ENABLED`, `JWT_SECRET`, …), and
a read-only ConfigMap mounted over it would clobber that (breaking JWT). PF
suppresses the store **per session** via `editorConfig.plugins.disable:[<marketplace-guid>]`
instead (best-effort — browser-verify). The store fetch is a **client-side**
browser call to onlyoffice.github.io, so the pod's zero-egress NetworkPolicy does
not stop it; a hard block would need a CSP on `docs.${DOMAIN}`
(`istio-ingress/20-virtualservices.yaml`) omitting `onlyoffice.github.io` +
`plugins-services.onlyoffice.com`, but a too-strict CSP breaks the editor — treat
that as a tested follow-up, not a prerequisite.

### Changing the plugins = image rebuild

The plugins live in the image, so a plugin change is an **image rebuild**: sync
`image/plugins/` from PF, run `.github/workflows/onlyoffice-image-build.yml` (it
also fires on a push touching `platform/manifests/onlyoffice/image/**`), then
re-pin the new digest in `09-deployment.yaml` and re-apply it.

## First-deploy sequence (over `ssh secforge`)

```bash
# 0. Build the image first: run the onlyoffice-image-build workflow (or push
#    a change under platform/manifests/onlyoffice/image/), make the GHCR
#    package public, and pin the digest in 09-deployment.yaml.

# 1. Generate + store the fleet JWT secret (mint a 1h admin token via the
#    admin-break-glass role; NEVER leave a root token Secret behind):
kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN=<admin-token> \
  bao kv put secret/apps/onlyoffice/jwt jwt_secret="$(openssl rand -base64 32)"

# 2. Load the OpenBao policy + k8s-auth role (05j reads openbao-root-token-tmp;
#    the vso.hcl update must be re-loaded too for the PF-side sync):
#    - bao policy write onlyoffice  < manifests/openbao/policies/onlyoffice.hcl
#    - bao policy write vso         < manifests/openbao/policies/vso.hcl
#    - platform/components/05j-app-vso-roles.sh   (idempotent; upserts all rows)

# 3. Apply manifests (from the box's ~/secforge checkout — git pull first):
kubectl apply -f platform/manifests/onlyoffice/01-namespace.yaml
kubectl apply -f platform/manifests/onlyoffice/03-serviceaccount.yaml
kubectl apply -f platform/manifests/onlyoffice/04-vso-bindings.yaml
kubectl apply -f platform/manifests/onlyoffice/05-network-policies.yaml
kubectl apply -f platform/manifests/onlyoffice/06-authorization-policy.yaml
kubectl apply -f platform/manifests/onlyoffice/07-resource-quota.yaml
kubectl apply -f platform/manifests/onlyoffice/09-deployment.yaml   # after digest pin
kubectl apply -f platform/manifests/onlyoffice/10-services.yaml

# 4. Kyverno exemption + gateway route + consumer wiring — ${DOMAIN} files MUST
#    go through the envsubst wrapper, never raw kubectl:
kubectl apply -f platform/manifests/kyverno/policies/06-require-runasnonroot.yaml
platform/lib/apply-manifest.sh platform/manifests/istio-ingress/20-virtualservices.yaml
kubectl apply -f platform/manifests/proposal-forge/05-network-policies.yaml
kubectl apply -f platform/manifests/proposal-forge/04-vso-bindings.yaml

# 5. Split-DNS: add docs.${DOMAIN} to the node dnsmasq + Tailscale split-DNS
#    set (platform/host — run host-config-drift-check.sh after).
```

## Verify

```bash
# Secret rendered in BOTH namespaces (and equal):
kubectl get secret onlyoffice-jwt -n onlyoffice
kubectl get secret onlyoffice-jwt -n proposal-forge

# Pod healthy (slow first boot — startupProbe allows ~5 min):
kubectl exec -n onlyoffice deploy/onlyoffice -- curl -s http://localhost/healthcheck
# → true

# Editor API loads via the gateway (operator tailnet device):
curl -s https://docs.<domain>/web-apps/apps/api/documents/api.js | head -c 200

# Example app is NOT served:
curl -s -o /dev/null -w '%{http_code}\n' https://docs.<domain>/example/   # → 404

# Zero-egress (must FAIL):
kubectl exec -n onlyoffice deploy/onlyoffice -- curl -s -m 5 https://example.com || echo "egress blocked (good)"

# Real round-trip before declaring done (MinIO cross-ns lesson): from a PF pod,
# POST a ConvertService request; watch the DS fetch the document and PF receive
# the callback.
```
