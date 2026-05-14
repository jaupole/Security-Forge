# App namespace template

Templated bootstrap for a new SecForge-hosted app. Run `bootstrap-app.sh`
with the app's parameters; it instantiates this template into a working
namespace with the platform's full security baseline.

## Parameters

Each app provides:

| Variable | Example | Purpose |
|---|---|---|
| `APP_NAME` | `proposal-forge` | Used for namespace name, SA names, prefix |
| `APP_DOMAIN` | `pf.secforge.dev` | Public ingress hostname |
| `APP_CPU_REQ` / `APP_CPU_LIMIT` | `100m` / `2` | ResourceQuota / LimitRange |
| `APP_MEM_REQ` / `APP_MEM_LIMIT` | `256Mi` / `4Gi` | ResourceQuota / LimitRange |
| `APP_OPENBAO_PATHS` | `secret/data/proposal-forge/*` | What KV paths it reads |
| `APP_TRUSTED_NAMESPACES` | `keycloak,observability` | Outbound NP allow-list |
| `APP_DB_CLUSTER` | `secforge-app-db` | Which CNPG cluster (optional) |

## What gets created (per app)

1. **Namespace** with PSA `restricted:enforce` + Istio Ambient label + `secforge.platform/app=true`
2. **NetworkPolicies**: default-deny ingress + egress, plus allow-lists for
   - DNS to kube-system
   - OpenBao at openbao.openbao.svc:8200 (read paths only)
   - In-cluster K8s API at 10.43.0.1:443 + host:6443
   - Ingress-nginx → app on app's HTTP port
   - App → trusted namespaces (configurable)
3. **ResourceQuota** + **LimitRange** sized to APP_CPU/MEM
4. **ServiceAccount** `app-default` with `automountServiceAccountToken: false`
5. **OpenBao K8s auth role** scoped to APP_OPENBAO_PATHS
6. **SPIRE ClusterSPIFFEID** matching pods labeled
   `spiffe.io/spire-managed-identity: "true"` in this namespace
7. **Istio AuthorizationPolicy** default-deny ingress; per-route ALLOW rules
   are added by the app's own Helm chart
8. **VSO `VaultStaticSecret` skeleton** ready to point at OpenBao paths
9. **ServiceMonitor selector label** so kube-prometheus-stack auto-scrapes
10. **Loki label** so Promtail auto-ships logs

## Usage

```bash
APP_NAME=proposal-forge \
APP_DOMAIN=pf.secforge.dev \
APP_CPU_REQ=200m APP_CPU_LIMIT=2 \
APP_MEM_REQ=512Mi APP_MEM_LIMIT=4Gi \
APP_OPENBAO_PATHS='secret/data/proposal-forge/*' \
APP_TRUSTED_NAMESPACES=keycloak,observability \
  bash platform/components/bootstrap-app.sh
```

## After bootstrap

The app's own Helm chart deploys *into* this namespace. The chart should:
- Use the SA `app-default` (or its own SA with the same restrictions)
- Label pods with `secforge.platform/app: "true"` (for image-sig policy)
- Label pods with `spiffe.io/spire-managed-identity: "true"` (for SVID)
- Mount SVIDs via `csi.spiffe.io` driver
- Reference VSO-rendered Secrets for any OpenBao paths

## Removing an app

```bash
kubectl delete namespace $APP_NAME
# Manually clean up OpenBao K8s auth role:
bao delete auth/kubernetes/role/$APP_NAME-vso
```
