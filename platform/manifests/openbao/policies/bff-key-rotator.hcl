# bff-key-rotator — bound to spiffe://secforge.local/ns/app/sa/bff-key-rotator
# via the JWT auth method's bff-key-rotator role.
#
# Capabilities for the Phase 7d.1 BFF key rotation CronJobs:
#   - read kcadm-admin client_secret (used by _lib/kcadm-auth.sh to
#     authenticate kcadm.sh in the keycloak-0 pod)
#   - read+create+update KV-v2 versions for each BFF client's PEM material
#
# Each BFF client path is listed explicitly (not globbed) so a typo in
# CLIENT_ID inside the rotation script can't accidentally write to an
# unrelated path.

# kcadm-admin client_secret — read-only, used by _lib/kcadm-auth.sh.
path "secret/data/keycloak/clients/kcadm-admin" {
  capabilities = ["read"]
}

# proposal-forge-bff (BFF deployment lands in Phase 9+; CronJob is
# pre-provisioned suspend:true until then)
path "secret/data/keycloak/clients/proposal-forge-bff" {
  capabilities = ["read", "create", "update"]
}
path "secret/metadata/keycloak/clients/proposal-forge-bff" {
  capabilities = ["read"]
}

# project-tracker-bff (same — suspend:true until Phase 9+)
path "secret/data/keycloak/clients/project-tracker-bff" {
  capabilities = ["read", "create", "update"]
}
path "secret/metadata/keycloak/clients/project-tracker-bff" {
  capabilities = ["read"]
}

# pm-bff (same — suspend:true until Phase 9+)
path "secret/data/keycloak/clients/pm-bff" {
  capabilities = ["read", "create", "update"]
}
path "secret/metadata/keycloak/clients/pm-bff" {
  capabilities = ["read"]
}
