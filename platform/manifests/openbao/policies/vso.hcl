# vso — Vault Secrets Operator policy.
#
# Bound to the SA `vault-secrets-operator-controller-manager` in the
# `vault-secrets-operator` namespace via the Kubernetes auth method's
# role `vault-secrets-operator` (configured by
# infrastructure/vault-secrets-operator/configure-openbao-role.sh).
#
# Phase 6.10b — Step 2. See ADR-0015.
#
# Scope: read-only access to the two paths whose secrets are operator-shaped
# and need K8s Secret rendering. Anything else (BFF private keys, future
# transit calls, dynamic DB creds) stays on direct-API via apps/lib/secrets/
# and is NOT in this policy. If a future workload needs VSO, add its path
# here in a separate ADR-referenced commit.

# SpiceDB preshared key (PSK-only) — read by VSO acting on behalf of the
# AuthZEN façade in the app namespace. AuthZEN does NOT need the Postgres
# datastore URI; this path is the narrowly-scoped PSK source for it.
path "secret/data/spicedb/preshared-key" {
  capabilities = ["read"]
}
path "secret/metadata/spicedb/preshared-key" {
  capabilities = ["read"]
}

# SpiceDB full config (PSK + datastore URI) — read by VSO acting on behalf
# of SpiceDB itself (operator-managed StatefulSet) in the spicedb namespace.
# Distinct path so AuthZEN's role can be denied access to the Postgres
# password (defense in depth — see ADR-0015 §"Open questions").
#
# datastore_uri here is a STATIC copy of the CNPG-managed Postgres
# connection string. CNPG password rotation will desync this value;
# the proper fix is OpenBao's database secrets engine for SpiceDB
# (already wired for helloworld-app in Phase 5.7). Tracked as a future
# follow-up post-6.10b.
path "secret/data/spicedb/config" {
  capabilities = ["read"]
}
path "secret/metadata/spicedb/config" {
  capabilities = ["read"]
}

# Keycloak client private_key_jwt keypairs — listed here defensively in
# case a future first-class app turns out to be operator-shaped and needs
# VSO. Today (Phase 6.10b), all four BFF clients are direct-API per
# ADR-0015 and these paths are NOT actually rendered. If you find yourself
# rendering one of these via VSO, document why in ADR-0015 first.
path "secret/data/keycloak/clients/+" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/+" {
  capabilities = ["read"]
}

# Grafana OIDC client_secret (Phase 7.3) — rendered into the
# observability namespace so the kube-prometheus-stack Helm chart can
# inject it into Grafana via envFromSecret. Grafana is operator-shaped
# (the chart owns the Deployment); per ADR-0015 it consumes through
# VSO rather than direct-API.
path "secret/data/grafana/oidc" {
  capabilities = ["read"]
}
path "secret/metadata/grafana/oidc" {
  capabilities = ["read"]
}

# MinIO scoped-user credentials for Loki (Phase 7.4) and Tempo (Phase 7.5).
# Each consumer has its own MinIO user with bucket-scoped policy; the
# access keys land here and VSO renders them into K8s Secrets in the
# observability namespace. apply-loki.sh / apply-tempo.sh provision the
# MinIO user, the policy, and stage the keys.
path "secret/data/minio/loki/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/loki/credentials" {
  capabilities = ["read"]
}
path "secret/data/minio/tempo/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/tempo/credentials" {
  capabilities = ["read"]
}

# MinIO scoped-user credentials for Velero (Phase 9 backups) and CNPG
# (per-cluster Postgres physical backups via Barman). Each consumer has
# its own MinIO user with prefix-scoped policy on the `backups` bucket;
# 09a-velero.sh / 09b-cnpg-backups.sh provision them.
path "secret/data/minio/velero/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/velero/credentials" {
  capabilities = ["read"]
}
path "secret/data/minio/cnpg/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/cnpg/credentials" {
  capabilities = ["read"]
}

# Velero kopia repository passphrase (Phase C #2 hardening).
# Replaces the chart-default `static-passw0rd` with a strong value.
# Provisioned by 09a-velero-rotate-passphrase.sh.
path "secret/data/platform/velero/kopia-passphrase" {
  capabilities = ["read"]
}
path "secret/metadata/platform/velero/kopia-passphrase" {
  capabilities = ["read"]
}

# MinIO SSE-S3 master key (Phase C #2 hardening).
# 32-byte master key wired into MinIO via MINIO_KMS_SECRET_KEY env var
# (format: `<key-name>:<base64-key>`). Once set + bucket auto-encryption
# is enabled (`mc encrypt set sse-s3 local/backups`), MinIO encrypts
# every new object at rest with AES-256-GCM. This covers BOTH:
#   - Velero K8s resource backups (the kopia-encrypted PV blobs are
#     re-encrypted at the storage layer for defense-in-depth)
#   - CNPG barman PostgreSQL physical backups + WAL (the only at-rest
#     encryption these get since CNPG/barman has no client-side mode)
# Provisioned by 09f-minio-sse-encryption.sh.
path "secret/data/platform/minio/sse-master-key" {
  capabilities = ["read"]
}
path "secret/metadata/platform/minio/sse-master-key" {
  capabilities = ["read"]
}

# Cloudflare API token for cert-manager DNS-01 ACME challenge.
# Provisioned by 00b-cert-manager.sh. Used by cert-manager for the
# Let's Encrypt staging + prod ClusterIssuers (DNS-01 challenge against
# the secforge.dev Cloudflare zone). Token has scope `Zone: DNS: Edit`
# restricted to ${DOMAIN}.
path "secret/data/platform/cert-manager/cloudflare" {
  capabilities = ["read"]
}
path "secret/metadata/platform/cert-manager/cloudflare" {
  capabilities = ["read"]
}

# Wazuh dashboard OIDC client_secret + issuer + redirect_uri (Phase 7d
# Item 7). Provisioned by platform/components/07i-keycloak-wazuh-client.sh
# and rendered into wazuh ns via VSO for the dashboard pod's
# opensearch_dashboards.yml config.
path "secret/data/wazuh/oidc" {
  capabilities = ["read"]
}
path "secret/metadata/wazuh/oidc" {
  capabilities = ["read"]
}

# Control plane API (control ns).
#   - keycloak/clients/control: OIDC client_secret for the user-login client
#   - keycloak/clients/control-admin: client_secret for the admin-API
#                                     service-account client (added 2026-05-15)
#   - apps/control/runtime: bundle of OIDC_CLIENT_SECRET,
#                           KEYCLOAK_ADMIN_CLIENT_SECRET, SPICEDB_PRESHARED_KEY,
#                           SESSION_KEY consumed via VSO-rendered K8s Secret
path "secret/data/keycloak/clients/control" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/control" {
  capabilities = ["read"]
}
path "secret/data/keycloak/clients/control-admin" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/control-admin" {
  capabilities = ["read"]
}
path "secret/data/apps/control/+" {
  capabilities = ["read"]
}
path "secret/metadata/apps/control/+" {
  capabilities = ["read", "list"]
}
