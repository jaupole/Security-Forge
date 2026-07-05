# onlyoffice — bound to k8s SA `onlyoffice-vso` (onlyoffice ns) via the
# kubernetes auth method's role `onlyoffice-vso` (APP_ROLES row in
# platform/components/05j-app-vso-roles.sh). DOCENG Phase 1.
#
# Capabilities:
#   - read the apps/onlyoffice/* KV paths — today just `jwt` (the Document
#     Server's single global JWT secret, key `jwt_secret`), rendered into the
#     onlyoffice ns by the VaultStaticSecret in
#     platform/manifests/onlyoffice/04-vso-bindings.yaml.
#
# Notes:
#   - The jwt path is FLEET-SHARED by design: consumer apps (proposal-forge
#     today, control next) sync the same path into their own namespaces via
#     their own VSO roles — those read grants live in vso.hcl, NOT here.
#   - No Transit, no MinIO, no other paths: the DS holds exactly one secret.

path "secret/data/apps/onlyoffice/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/onlyoffice/*" {
  capabilities = ["read"]
}
