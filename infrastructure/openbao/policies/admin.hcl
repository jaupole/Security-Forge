# admin — full platform access. Mapped only to the Keycloak realm role
# `platform_admin` via the OIDC auth method's role binding. Intentionally
# uses `*` capabilities; the gating is at the OIDC layer.

path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
