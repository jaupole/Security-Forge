# Keycloak — Local Edition

This directory holds everything needed to deploy Keycloak (Phase 3) on the local Docker Desktop cluster.

| Path | Purpose |
|---|---|
| `operator/` | Pinned upstream Keycloak Operator manifests (CRDs + operator deployment) for v26.3.3 |
| `01-serviceaccount.yaml` | `keycloak` ServiceAccount in the `keycloak` namespace (gives the pod its SPIFFE ID `…/sa/keycloak`) |
| `02-bootstrap-admin.example.yaml` | **Reference only** — actual Secret is created by `apply.sh`, never committed |
| `03-certificate.yaml` | cert-manager `Certificate` resources for `auth.secforge.local` and `auth-admin.secforge.local` |
| `04-keycloak-cr.yaml` | The Keycloak custom resource (the main one) |
| `05-ingress-public.yaml` | Ingress for `auth.secforge.local` (public OIDC endpoints) |
| `06-ingress-admin.yaml` | Ingress for `auth-admin.secforge.local` (admin console) — added in Phase 3.6 |
| `07-networkpolicies.yaml` | NetworkPolicies (default-deny + allow-from-ingress + allow-to-postgres) — Phase 3.6 |
| `realms/` | KeycloakRealmImport manifests for `platform` and `secforge-tenants` — Phase 3.4 |
| `apply.sh` | Idempotent local-edition installer |
| `uninstall.sh` | Tear-down (NOT for production; deletes CRs and CRDs) |

Companion docs:
- Architecture: [docs/01-architecture/01-iam-platform.md](../../docs/01-architecture/01-iam-platform.md)
- ADR-0006: [docs/02-decisions/0006-keycloak-keys-local.md](../../docs/02-decisions/0006-keycloak-keys-local.md)
- ADR-0007: [docs/02-decisions/0007-totp-instead-of-passkeys-locally.md](../../docs/02-decisions/0007-totp-instead-of-passkeys-locally.md)
- Runbook: [docs/03-runbooks/keycloak-operations.md](../../docs/03-runbooks/keycloak-operations.md)

## Quick reference

```bash
# Install (idempotent)
./apply.sh

# Watch the pod come up
kubectl -n keycloak get pods -w

# Discovery doc
curl -ks https://auth.secforge.local/realms/master/.well-known/openid-configuration | jq .

# Bootstrap admin login (one-time, see apply.sh output)
# https://auth-admin.secforge.local/admin (after Phase 3.6)
```

## Versioning

| Component | Version | Source |
|---|---|---|
| Keycloak | 26.3.3 | quay.io/keycloak/keycloak:26.3.3 |
| Keycloak Operator | 26.3.3 | quay.io/keycloak/keycloak-operator:26.3.3 |
| Operator manifests | 26.3.3 | github.com/keycloak/keycloak-k8s-resources @ 26.3.3 |
