# project-manager — bound to k8s SA `project-manager-vso` via the kubernetes
# auth method's role (for VSO rendering), and optionally to
# spiffe://${SPIFFE_TRUST_DOMAIN}/ns/project-manager/sa/project-manager
# via the JWT auth method's role (for Transit encrypt/decrypt).
#
# Capabilities:
#   - read the bundled `apps/project-manager/runtime` KV blob
#     (oidc_client_secret, oidc_client_secret_tenants, spicedb_psk,
#     session_signing_key)
#   - read GHCR pull credentials from `apps/project-manager/ghcr-pull`
#   - read shared CNPG barman MinIO credentials from `minio/cnpg/credentials`
#   - encrypt + decrypt via Transit (PII at rest)
#
# K8s auth role binding (k8s SA `project-manager-vso` → this policy) must be
# created via OpenBao bootstrap. Example:
#   bao write auth/kubernetes/role/project-manager-vso \
#     bound_service_account_names=project-manager-vso \
#     bound_service_account_namespaces=project-manager \
#     policies=project-manager \
#     ttl=1h

# Bundled runtime secrets blob. VSO reads this via the k8s-auth path.
path "secret/data/apps/project-manager/runtime" {
  capabilities = ["read"]
}
path "secret/metadata/apps/project-manager/runtime" {
  capabilities = ["read"]
}

# GHCR pull credentials.
path "secret/data/apps/project-manager/ghcr-pull" {
  capabilities = ["read"]
}
path "secret/metadata/apps/project-manager/ghcr-pull" {
  capabilities = ["read"]
}

# barman-cloud → MinIO credentials for the project-manager-db CNPG cluster's
# WAL archiving + base backups. Shared path across all CNPG clusters.
path "secret/data/minio/cnpg/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/cnpg/credentials" {
  capabilities = ["read"]
}

# Field-level PII encryption — Transit key shared with other apps.
path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}
