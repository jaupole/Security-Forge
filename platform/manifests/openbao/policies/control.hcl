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
# `pii-org-<orgId>` key.
#
# The wildcard encrypt/decrypt/rewrap capabilities below are used by
# BACKGROUND workers (rewrap script, rotation script, signup wizard's
# initial key mint) where cross-org access is legitimate. Per-REQUEST
# code paths (the user-facing API handling one active org per request)
# mint a short-TTL child token via `auth/token/create` below, which
# inherits the `pii-org-request` policy — narrowing decrypt rights to
# the active org's key for the duration of that request. See the
# `auth/token/create` block at the bottom of this file + the
# `pii-org-request.hcl` policy in the same directory.
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

# Per-request token scoping — Control mints short-TTL child tokens
# bearing `pii-org-request` policy + `active_org_id` metadata, so
# the in-process decrypt path used by user-facing requests is bound
# to the active org's Transit key only. Without this capability the
# parent token still works (cross-org) but the per-request hardening
# can't operate.
path "auth/token/create" {
  capabilities = ["update"]
}
