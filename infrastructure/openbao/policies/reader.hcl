# reader — default policy for OIDC-authenticated users. Allows reading
# only the user's own KV namespace. All other paths denied.

path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/users/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
