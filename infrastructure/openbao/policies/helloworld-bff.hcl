# helloworld-bff — bound to spiffe://secforge.local/ns/app/sa/helloworld-bff
# via the JWT auth method's role.
#
# Capabilities:
#   - read the BFF's own private_key_jwt PEM at startup (Phase 6.6 / 6.8)
#   - read static config under secret/data/apps/helloworld/<key>
#   - mint dynamic Postgres credentials via database/creds/helloworld-app-readwrite
#   - encrypt + decrypt via Transit (PII at rest in the app DB)

# BFF startup: read its Keycloak client private_key_jwt signing key.
# The KV path was populated by Phase 5.10's migrate-secrets.sh; this
# read is what makes Phase 6.10b's "OpenBao authoritative" cutover real
# for the BFF (the K8s Secret app/bff-jwt-helloworld-bff stops being read).
path "secret/data/keycloak/clients/helloworld-bff" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/helloworld-bff" {
  capabilities = ["read"]
}

path "secret/data/apps/helloworld/+" {
  capabilities = ["read"]
}
path "secret/metadata/apps/helloworld/+" {
  capabilities = ["read", "list"]
}

path "database/creds/helloworld-app-readwrite" {
  capabilities = ["read"]
}

path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}
