# keycloak-ghcr — bound to the keycloak/keycloak-ghcr-vso ServiceAccount via
# the kubernetes-auth role `keycloak-ghcr-vso` (created in 05j-app-vso-roles.sh).
#
# Sole purpose: let the Keycloak namespace's Vault Secrets Operator binding
# (manifests/keycloak/03b-ghcr-vso-binding.yaml) render the ghcr.io pull
# credential at secret/data/apps/control/ghcr-pull into the dockerconfigjson
# Secret `ghcr-pull-secret`, so the Keycloak Operator's StatefulSet can pull
# the private custom image ghcr.io/jaupole/keycloak.
#
# WHY a dedicated scoped policy instead of reusing the shared `vso` policy
# (as kyverno-vso does in 12c): least privilege. vso.hcl grants read on ALL of
# secret/data/apps/control/+ ; Keycloak needs only the single ghcr-pull key.
# This replaces a stale hand-created pull Secret (dead PAT) that broke the
# 26.6.2 deploy with ErrImagePull — VSO now auto-refreshes it on PAT rotation.
path "secret/data/apps/control/ghcr-pull" {
  capabilities = ["read"]
}
path "secret/metadata/apps/control/ghcr-pull" {
  capabilities = ["read"]
}
