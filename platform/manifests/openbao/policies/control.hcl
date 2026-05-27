# control — bound to spiffe://${SPIFFE_TRUST_DOMAIN}/ns/control/sa/control
# via the JWT auth method's role.
#
# Capabilities:
#   - read its Keycloak OIDC client_secret (issued by realm bootstrap)
#   - read SpiceDB pre-shared key (rendered as a K8s Secret in spicedb ns
#     but the API also has a path in case of cluster-internal direct fetch)
#   - read session-signing key for @fastify/secure-session
#   - read app-level config + outbound integration secrets under
#     secret/data/apps/control/<key>
#   - encrypt + decrypt via Transit (PII at rest in control DB — rule 38)
#
# NOTE: the K8s auth role binding `control-vso` (k8s SA → this policy)
# lives in the openbao bootstrap script, NOT in a manifest. Re-running
# the bootstrap on a fresh cluster re-creates the role; ongoing changes
# go through `bao write auth/kubernetes/role/control-vso ...`.

# Keycloak OIDC client_secret. Operator writes this once after creating
# the `control` client in the platform realm.
path "secret/data/keycloak/clients/control" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/control" {
  capabilities = ["read"]
}

# App-level config (SpiceDB PSK, session-signing key, etc.) + future
# outbound integrations follow the same `+` (one segment) pattern as
# the BFF policy.
path "secret/data/apps/control/+" {
  capabilities = ["read"]
}
path "secret/metadata/apps/control/+" {
  capabilities = ["read", "list"]
}

# Field-level PII encryption — invitations, member emails, etc.
# (Closes audit rule 38 once the .Encrypt() call sites land in code.)
path "transit/encrypt/pii-encryption" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-encryption" {
  capabilities = ["update"]
}

# Per-tenant Transit keys for vendor credentials (Stripe / QBO / SMTP /
# Postmark / OIDC) — every org's *_enc columns wrap onto its own
# `pii-org-<orgId>` key so compromise of one org's plaintext (via an
# attacker reading the ciphertext from the DB + calling our decrypt
# path with that org's keyName) does not extend to other orgs.
#
# The key is minted at org-create time by the signup/admin/sub-org
# routes via the TransitClient.createKey() helper; the create capability
# below is what lets that mint succeed. Rotation walks the same paths
# (rotateKey + rewrap).
#
# Per-REQUEST scoping (narrowing the in-process decrypt token to one
# org per request) was attempted via `pii-org-request` + `auth/token/
# create` but rolled back 2026-05-27 — OpenBao's policy template
# system does not expose token-creation-time metadata to templates,
# so the scoped policy can't resolve to the active org's key. Deferred
# to a JWT-claim-mapping rewrite (see project_per_request_token_scoping
# memory entry).
path "transit/keys/pii-org-*" {
  capabilities = ["create", "read", "update"]
}
path "transit/encrypt/pii-org-*" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-org-*" {
  capabilities = ["update"]
}
path "transit/rewrap/pii-org-*" {
  capabilities = ["update"]
}
