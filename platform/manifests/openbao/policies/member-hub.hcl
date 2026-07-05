# member-hub — bound to spiffe://${SPIFFE_TRUST_DOMAIN}/ns/member-hub/sa/member-hub
# via the JWT auth method's role (for Transit encrypt/decrypt) AND to k8s SA
# `member-hub-vso` via the kubernetes auth method's role (for VSO rendering).
#
# Capabilities:
#   - read the bundled `apps/member-hub/runtime` KV blob (oidc_client_secret,
#     admin_client_secret, spicedb_psk, session_signing_key, email_hmac_key)
#   - encrypt + decrypt via Transit (PII at rest in member-hub DB — rule 38)
#
# Notes:
#   - K8s auth role binding (k8s SA `member-hub-vso` → this policy) lives in
#     the openbao bootstrap script. Ongoing changes via `bao write auth/kubernetes/role/member-hub-vso ...`.
#   - JWT auth role for Transit access is bound to the SPIFFE-issued JWT-SVID
#     the spiffe-helper sidecar fetches (audience: openbao). Configured in
#     the same bootstrap.

# Bundled runtime secrets blob. VSO reads this via the k8s-auth path,
# the app code reads via SPIFFE-JWT-auth only if it ever needs direct
# API access (today everything is rendered into a K8s Secret + envFrom).
path "secret/data/apps/member-hub/runtime" {
  capabilities = ["read"]
}
path "secret/metadata/apps/member-hub/runtime" {
  capabilities = ["read"]
}

# barman-cloud → MinIO credentials for the member-hub-db CNPG cluster's
# WAL archiving + base backups. Same shared path as every other CNPG
# cluster's barman; the cnpg-minio-credentials-vso VaultStaticSecret in
# 04-vso-bindings.yaml reads it under this app's K8s-auth role.
path "secret/data/minio/cnpg/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/cnpg/credentials" {
  capabilities = ["read"]
}

# App-level MinIO credentials for the member-hub-documents bucket
# (member file attachments). Distinct from the CNPG barman creds
# above — this is a bucket-scoped service account with rw on the
# documents bucket only, no access to backups/loki/etc. Provisioned
# imperatively via `mc admin policy create` + `mc admin user svcacct
# add`; rotate by issuing a new svc account, writing it here, and
# bouncing the member-hub pod.
path "secret/data/minio/member-hub-documents" {
  capabilities = ["read"]
}
path "secret/metadata/minio/member-hub-documents" {
  capabilities = ["read"]
}

# Field-level PII encryption — member emails, future invitations, etc.
# Closes audit rule 38 once .Encrypt() call sites land in code.
path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}

# Shared ONLYOFFICE Document Server JWT secret for the staff document viewer
# (FLEET-MH1). One secret, N namespaces — rotate once in OpenBao and every VSO
# sync follows. Rendered as ONLYOFFICE_JWT_SECRET via the onlyoffice-jwt
# VaultStaticSecret (04-vso-bindings.yaml). MH's VSO role binds ONLY this
# `member-hub` policy, so the grant lives here.
path "secret/data/apps/onlyoffice/jwt" {
  capabilities = ["read"]
}
path "secret/metadata/apps/onlyoffice/jwt" {
  capabilities = ["read"]
}
