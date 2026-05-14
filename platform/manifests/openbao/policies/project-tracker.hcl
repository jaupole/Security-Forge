# project-tracker — bound to spiffe://secforge.local/ns/app/sa/project-tracker-backend
# via the JWT auth method's role.
#
# Capabilities (intentionally narrow):
#   - mint runtime Postgres credentials via database/creds/project-tracker-readwrite
#     (default_ttl=1h; the dynamic role inherits project_tracker_app and
#      can SELECT/INSERT/UPDATE/DELETE on project_tracker.*)
#   - mint short-lived migration credentials via database/creds/project-tracker-migrate
#     (default_ttl=15m; CREATE/ALTER/DROP rights on project_tracker schema)
#   - read SAM.gov API key + any future static config under
#     secret/data/apps/project-tracker/*
#
# NOT granted:
#   - secret/data/keycloak/* — only the project-tracker BFF (separate policy)
#     talks to Keycloak's token endpoints
#   - transit/* — backend doesn't encrypt/decrypt anything in 10.1.3 scope
#   - any * permission on database/* — explicit per-role grants only
#
# Phase 10.1.3 establishes this policy alongside the Postgres schema +
# RLS migration. Phase 10.1.5 wires the SAM.gov key consumer code to
# fetch via this policy's secret/data/apps/project-tracker/sam-gov path.

path "database/creds/project-tracker-readwrite" {
  capabilities = ["read"]
}

path "database/creds/project-tracker-migrate" {
  capabilities = ["read"]
}

path "secret/data/apps/project-tracker/*" {
  capabilities = ["read"]
}
