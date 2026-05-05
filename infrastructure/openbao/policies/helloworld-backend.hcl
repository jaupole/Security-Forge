# helloworld-backend — bound to spiffe://secforge.local/ns/app/sa/helloworld-backend
# via the JWT auth method's role.
#
# Capabilities (intentionally narrow — backend only needs Postgres):
#   - mint dynamic Postgres credentials via database/creds/helloworld-backend-readwrite
#
# NOT granted (and intentionally so):
#   - secret/data/apps/helloworld-backend/* — backend has no static config
#   - transit/* — backend doesn't encrypt/decrypt anything in this demo
#   - secret/data/keycloak/* — only the BFF talks to Keycloak's token endpoints
#
# Phase 9.12 teardown removes this policy and the bound JWT auth role.

path "database/creds/helloworld-backend-readwrite" {
  capabilities = ["read"]
}
