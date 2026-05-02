# vso — Vault Secrets Operator policy.
#
# Bound to the SA `vault-secrets-operator-controller-manager` in the
# `vault-secrets-operator` namespace via the Kubernetes auth method's
# role `vault-secrets-operator` (configured by
# infrastructure/vault-secrets-operator/configure-openbao-role.sh).
#
# Phase 6.10b — Step 2. See ADR-0015.
#
# Scope: read-only access to the two paths whose secrets are operator-shaped
# and need K8s Secret rendering. Anything else (BFF private keys, future
# transit calls, dynamic DB creds) stays on direct-API via apps/lib/secrets/
# and is NOT in this policy. If a future workload needs VSO, add its path
# here in a separate ADR-referenced commit.

# SpiceDB preshared key (PSK-only) — read by VSO acting on behalf of the
# AuthZEN façade in the app namespace. AuthZEN does NOT need the Postgres
# datastore URI; this path is the narrowly-scoped PSK source for it.
path "secret/data/spicedb/preshared-key" {
  capabilities = ["read"]
}
path "secret/metadata/spicedb/preshared-key" {
  capabilities = ["read"]
}

# SpiceDB full config (PSK + datastore URI) — read by VSO acting on behalf
# of SpiceDB itself (operator-managed StatefulSet) in the spicedb namespace.
# Distinct path so AuthZEN's role can be denied access to the Postgres
# password (defense in depth — see ADR-0015 §"Open questions").
#
# datastore_uri here is a STATIC copy of the CNPG-managed Postgres
# connection string. CNPG password rotation will desync this value;
# the proper fix is OpenBao's database secrets engine for SpiceDB
# (already wired for helloworld-app in Phase 5.7). Tracked as a future
# follow-up post-6.10b.
path "secret/data/spicedb/config" {
  capabilities = ["read"]
}
path "secret/metadata/spicedb/config" {
  capabilities = ["read"]
}

# Keycloak client private_key_jwt keypairs — listed here defensively in
# case a future first-class app turns out to be operator-shaped and needs
# VSO. Today (Phase 6.10b), all four BFF clients are direct-API per
# ADR-0015 and these paths are NOT actually rendered. If you find yourself
# rendering one of these via VSO, document why in ADR-0015 first.
path "secret/data/keycloak/clients/+" {
  capabilities = ["read"]
}
path "secret/metadata/keycloak/clients/+" {
  capabilities = ["read"]
}

# Grafana OIDC client_secret (Phase 7.3) — rendered into the
# observability namespace so the kube-prometheus-stack Helm chart can
# inject it into Grafana via envFromSecret. Grafana is operator-shaped
# (the chart owns the Deployment); per ADR-0015 it consumes through
# VSO rather than direct-API.
path "secret/data/grafana/oidc" {
  capabilities = ["read"]
}
path "secret/metadata/grafana/oidc" {
  capabilities = ["read"]
}

# MinIO scoped-user credentials for Loki (Phase 7.4) and Tempo (Phase 7.5).
# Each consumer has its own MinIO user with bucket-scoped policy; the
# access keys land here and VSO renders them into K8s Secrets in the
# observability namespace. apply-loki.sh / apply-tempo.sh provision the
# MinIO user, the policy, and stage the keys.
path "secret/data/minio/loki/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/loki/credentials" {
  capabilities = ["read"]
}
path "secret/data/minio/tempo/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/tempo/credentials" {
  capabilities = ["read"]
}

# Wazuh dashboard OIDC client_secret + issuer + redirect_uri (Phase 7d
# Item 7). Provisioned by infrastructure/keycloak/clients/wazuh.sh and
# rendered into wazuh ns via VSO for the dashboard pod's
# opensearch_dashboards.yml config.
path "secret/data/wazuh/oidc" {
  capabilities = ["read"]
}
path "secret/metadata/wazuh/oidc" {
  capabilities = ["read"]
}

# Teleport OIDC client_secret + issuer + redirect_uri (Phase 8a Step 4).
# Provisioned by infrastructure/keycloak/clients/teleport.sh and
# rendered into teleport ns by VSO for the auth pod's OIDCConnector
# config (Phase 8b).
path "secret/data/teleport/oidc" {
  capabilities = ["read"]
}
path "secret/metadata/teleport/oidc" {
  capabilities = ["read"]
}

# Teleport scoped MinIO user creds (session-recording bucket access).
# Provisioned by infrastructure/teleport/apply-minio-user.sh and
# rendered into teleport ns by VSO for the auth pod's S3 backend
# config (Phase 8b).
path "secret/data/minio/teleport/credentials" {
  capabilities = ["read"]
}
path "secret/metadata/minio/teleport/credentials" {
  capabilities = ["read"]
}
