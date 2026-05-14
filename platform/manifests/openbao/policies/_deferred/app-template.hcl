# app-template.hcl — Templated per-app OpenBao policy
#
# Per ADR-0013 § 4: a single templated policy enforces per-app authorization
# via OpenBao's identity templating, substituting the SPIFFE-ID's metadata.app
# attribute into the KV-v2 and database-engine paths. Cross-app reads are
# denied at the OpenBao policy layer (HTTP 403), not just the app layer.
#
# Bootstrap:
#   1. Discover the JWT mount accessor:
#        ACCESSOR=$(bao auth list -format=json | jq -r '."jwt/".accessor')
#
#   2. Substitute {{JWT_ACCESSOR}} below with $ACCESSOR (the bootstrap
#      script in commit 6's runbook handles this — sed-substitute or
#      envsubst at write-time):
#        sed "s/{{JWT_ACCESSOR}}/$ACCESSOR/g" app-template.hcl | bao policy write app-template -
#
#   3. Bind to a per-app role with token_metadata=app=<app-name>:
#        bao write auth/jwt/role/<app-name> \
#          bound_audiences=openbao \
#          user_claim=sub \
#          bound_subject=spiffe://secforge.local/ns/app/sa/<app-name> \
#          token_metadata=app=<app-name> \
#          token_policies=app-template \
#          token_ttl=15m \
#          token_max_ttl=1h
#
# Verify cross-app denial:
#   - App "foo" auths via SPIFFE-JWT; policy resolves metadata.app=foo.
#   - GET secret/data/apps/foo/stripe   → 200 (own path).
#   - GET secret/data/apps/bar/stripe   → 403 (cross-app, denied at policy).

path "secret/data/apps/{{identity.entity.aliases.{{JWT_ACCESSOR}}.metadata.app}}/*" {
  capabilities = ["read"]
}

path "database/creds/{{identity.entity.aliases.{{JWT_ACCESSOR}}.metadata.app}}-*" {
  capabilities = ["read"]
}
