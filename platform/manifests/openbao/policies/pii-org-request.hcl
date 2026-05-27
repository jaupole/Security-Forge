# pii-org-request — per-request scoped policy for per-org Transit ops.
#
# Minted by Control via `auth/token/create` right before a per-org
# Transit encrypt/decrypt/rewrap. The parent caller passes the active
# org's UUID in the token's metadata:
#
#   bao write auth/token/create \
#     policies=pii-org-request \
#     metadata=active_org_id=<orgId> \
#     ttl=60s
#
# The resulting child token's identity carries that metadata, and the
# templated path below resolves to `transit/decrypt/pii-org-<orgId>`
# at evaluation time. Decrypt rights are therefore SCOPED to the active
# org for that request, not the global `pii-org-*` wildcard Control's
# parent policy holds.
#
# Significance: an in-process compromise (RCE in Control during a
# request handling Org A) gives the attacker a child token capable of
# decrypting ONLY Org A's key — not the cross-tenant exfil the parent
# token's wildcard policy would otherwise permit. Background workers
# (rewrap, rotation scripts) keep the parent token's broader access
# because they legitimately operate across orgs.
#
# The template variable `{{identity.token.metadata.active_org_id}}`
# reads the TOKEN metadata (set by `auth/token/create -metadata=...`),
# distinct from identity entity metadata. Tokens get rejected by
# OpenBao's policy engine if the variable is unset, so an attacker
# minting a child token without metadata gets a useless one.

path "transit/encrypt/pii-org-{{identity.token.metadata.active_org_id}}" {
  capabilities = ["update"]
}
path "transit/decrypt/pii-org-{{identity.token.metadata.active_org_id}}" {
  capabilities = ["update"]
}
path "transit/rewrap/pii-org-{{identity.token.metadata.active_org_id}}" {
  capabilities = ["update"]
}
