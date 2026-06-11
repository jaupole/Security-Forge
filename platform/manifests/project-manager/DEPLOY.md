# Project Manager — Production Deploy Runbook

Tailnet-only app: `projects.${DOMAIN}` → `${TAILNET_IP}`. No public DNS A record.

---

## 0. Prerequisites

- `DOMAIN` and `TAILNET_IP` exported (or set in `platform/globals.env`)
- `STORAGE_CLASS` exported (matches the platform storage class, e.g. `local-path`)
- Cluster reachable: `ssh secforge sudo kubectl get nodes`
- OpenBao unsealed: `bao status` shows `Initialized: true  Sealed: false`
- First image built + signed: run the `project-manager-image-build` GHA workflow
  on the `project-manager` repo and note the `sha256:…` digest from the summary.

---

## 1. Populate OpenBao Secrets

SSH to the prod box and exec into the openbao pod, or use the admin-break-glass
token pattern from `platform/components/05l-keycloak-secret-publish.sh`.

```bash
# Runtime secrets blob (Keycloak, SpiceDB, session key)
bao kv put secret/apps/project-manager/runtime \
  oidc_client_secret="PLACEHOLDER_platform_realm_secret" \
  oidc_client_secret_tenants="PLACEHOLDER_tenants_realm_secret" \
  spicedb_psk="$(bao kv get -field=preshared_key secret/apps/spicedb/runtime)" \
  session_signing_key="$(openssl rand -base64 32)"

# GHCR pull credential (classic PAT, read:packages scope)
bao kv put secret/apps/project-manager/ghcr-pull \
  username="jaupole" \
  password="PLACEHOLDER_classic_pat"
```

The barman MinIO credentials at `secret/data/minio/cnpg/credentials` already
exist (shared across all CNPG clusters) — no action needed.

---

## 2. Register OpenBao Auth Roles

```bash
# VSO k8s auth role (lets project-manager-vso SA render secrets)
bao write auth/kubernetes/role/project-manager-vso \
  bound_service_account_names=project-manager-vso \
  bound_service_account_namespaces=project-manager \
  policies=project-manager \
  ttl=1h

# JWT auth role for Transit (spiffe-helper sidecar → OpenBao Transit)
bao write auth/jwt/role/project-manager \
  role_type=jwt \
  bound_audiences=openbao \
  user_claim=sub \
  bound_subject="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/project-manager/sa/project-manager" \
  policies=project-manager \
  ttl=15m
```

Apply the OpenBao policy:
```bash
bao policy write project-manager platform/manifests/openbao/policies/project-manager.hcl
```

---

## 3. Create Keycloak Clients

Create a confidential client `project-manager` in BOTH realms.
Reference: `platform/components/05h-keycloak-openbao-client.sh` for the
kcadm.sh pattern; `platform/components/05l-keycloak-secret-publish.sh` for
how secrets are published to OpenBao afterward.

### Platform realm (operator/member sign-in)

```bash
# Via kcadm.sh or the Keycloak admin console at kc.${DOMAIN}
kcadm.sh create clients -r platform \
  -s clientId=project-manager \
  -s enabled=true \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s 'redirectUris=["https://projects.'"${DOMAIN}"'/auth/callback"]' \
  -s 'webOrigins=["https://projects.'"${DOMAIN}"'"]'

# Add audience self-mapper (required per project_keycloak_audience_mappers memory)
CLIENT_ID=$(kcadm.sh get clients -r platform -q clientId=project-manager --fields id --format csv --noquotes)
kcadm.sh create clients/$CLIENT_ID/protocol-mappers/models -r platform \
  -s name=project-manager-audience \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-audience-mapper \
  -s 'config."included.client.audience"=project-manager' \
  -s 'config."access.token.claim"=true'
```

### Tenants realm (optional — for tenant user sign-in)

Repeat the above against `-r secforge-tenants` with the same redirectUri.

### Publish secrets to OpenBao

Add `project-manager` and (optionally) the tenants-realm variant to the
`CLIENT_DESTINATIONS` table in `platform/components/05l-keycloak-secret-publish.sh`
and re-run:
```bash
bash platform/components/05l-keycloak-secret-publish.sh
```
Or patch manually:
```bash
bao kv patch secret/apps/project-manager/runtime \
  oidc_client_secret="<actual_secret_from_keycloak>"
```

---

## 4. Apply Manifests

Run from the `Security Forge/platform` directory on the prod box (or locally
via `ssh secforge sudo kubectl apply -f`). The `apply-manifest.sh` wrapper
runs `envsubst` over `${DOMAIN}`, `${TAILNET_IP}`, `${STORAGE_CLASS}` before
applying — confirm these are in env.

```bash
cd ~/secforge/platform && git pull

# Namespace + RBAC + storage
bash lib/apply-manifest.sh manifests/project-manager/01-namespace.yaml
bash lib/apply-manifest.sh manifests/project-manager/03-serviceaccount.yaml

# CNPG cluster + backups
bash lib/apply-manifest.sh manifests/project-manager/02-cnpg-cluster.yaml
bash lib/apply-manifest.sh manifests/project-manager/06-objectstore.yaml
bash lib/apply-manifest.sh manifests/project-manager/07-cnpg-scheduled-backup.yaml

# VSO bindings (renders secrets; wait ~60s for VSO to populate)
bash lib/apply-manifest.sh manifests/project-manager/04-vso-bindings.yaml

# OpenBao CA ConfigMap (must populate ca.crt before applying deployment)
# Option A: run the bootstrap step that copies the cert from openbao ns:
#   bash platform/components/08a-openbao-ca-configmap.sh project-manager
# Option B: apply the placeholder and patch manually:
bash lib/apply-manifest.sh manifests/project-manager/08a-openbao-ca-configmap.yaml

# SPIFFE helper config
bash lib/apply-manifest.sh manifests/project-manager/08b-spiffe-helper-config.yaml

# Network policies (project-manager ns)
bash lib/apply-manifest.sh manifests/project-manager/05-network-policies.yaml

# SpiceDB cross-ns ingress policy (applies to spicedb namespace)
bash lib/apply-manifest.sh manifests/project-manager/12-allow-project-manager-to-spicedb.yaml

# Migration job — bump image digest first!
# Edit 08-migration-job.yaml: replace DIGEST_PLACEHOLDER with sha256:... from GHA summary
bash lib/apply-manifest.sh manifests/project-manager/08-migration-job.yaml

# Wait for migration to complete
kubectl -n project-manager wait --for=condition=complete job/project-manager-db-migrate --timeout=120s
kubectl -n project-manager logs job/project-manager-db-migrate -c migrate

# Deployment + service
# Edit 09-backend-deployment.yaml: replace DIGEST_PLACEHOLDER with the same digest
bash lib/apply-manifest.sh manifests/project-manager/09-backend-deployment.yaml
bash lib/apply-manifest.sh manifests/project-manager/10-services.yaml

# Istio routing (applies into istio-ingress namespace)
bash lib/apply-manifest.sh manifests/project-manager/11-istio-routing.yaml
```

**Note:** `13-kyverno-image-verify-note.yaml` is documentation only — do NOT apply it.

---

## 5. DNS — Tailnet Split-DNS

`projects.${DOMAIN}` is tailnet-only (no public A record). Add it to the
operator's split-DNS or `/etc/hosts`:

```
${TAILNET_IP}  projects.secforge.dev
```

On Tailscale: add `projects.${DOMAIN}` to the node's dnsmasq override
(`/etc/dnsmasq.d/secforge.conf`) pointing at `${TAILNET_IP}`, then
`systemctl restart dnsmasq`. Mirrors the pattern for `pf.secforge.dev`
and `bm.secforge.dev`.

---

## 6. Smoke Test

```bash
# Health probes via kubectl port-forward (before DNS is set)
kubectl -n project-manager port-forward svc/project-manager 3003:80 &
curl -sf http://localhost:3003/healthz && echo OK
curl -sf http://localhost:3003/readyz  && echo OK
kill %1

# Over Tailnet (after DNS is configured)
curl -sf https://projects.${DOMAIN}/healthz && echo OK
```

---

## 7. Subsequent Image Updates

1. Let the `project-manager-image-build` GHA workflow complete and note the digest.
2. Update `image:` in both `08-migration-job.yaml` and `09-backend-deployment.yaml`.
3. Delete the old migration Job and re-apply (Jobs are immutable; re-apply only works for the first apply):
   ```bash
   kubectl -n project-manager delete job project-manager-db-migrate --ignore-not-found
   bash lib/apply-manifest.sh manifests/project-manager/08-migration-job.yaml
   kubectl -n project-manager wait --for=condition=complete job/project-manager-db-migrate --timeout=120s
   ```
4. Apply the deployment:
   ```bash
   bash lib/apply-manifest.sh manifests/project-manager/09-backend-deployment.yaml
   kubectl -n project-manager rollout status deployment/project-manager
   ```

---

## Required `${VARS}` for apply-manifest.sh / envsubst

| Variable         | Where set            | Example value           |
|------------------|----------------------|-------------------------|
| `${DOMAIN}`      | `platform/globals.env` | `secforge.dev`        |
| `${TAILNET_IP}`  | `platform/globals.env` | `100.77.117.112`      |
| `${STORAGE_CLASS}` | `platform/globals.env` | `local-path`        |
| `${SPIFFE_TRUST_DOMAIN}` | OpenBao bootstrap context | `secforge.local` |
