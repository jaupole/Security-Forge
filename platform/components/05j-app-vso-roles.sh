#!/usr/bin/env bash
# 05j — App-level OpenBao kubernetes-auth roles.
#
# Creates idempotent k8s-auth roles for first-class apps that consume
# OpenBao via VSO (and, where applicable, dedicated audit-signing SAs).
# Per-platform-component roles (kyverno-vso, cert-manager-vso, grafana-vso,
# wazuh-vso, etc.) live in their own component scripts (12c, 07*, …).
# This one is for application namespaces only.
#
# Closes operator-backlog #11 — the live cluster carried these roles only
# in memory (added via break-glass during 2026-05-22 Phase B deploy of
# Control and Member Hub); cluster rebuild would have lost them.
#
# Adding a new app: append a row to the APP_ROLES table below. The role
# name MUST match what the app's VaultAuth CR references.
#
# Pre-condition: 05c ran (kubernetes auth method enabled, vso + audit-signer
# policies loaded, transit/keys/audit-signing created).
#
# Idempotent — re-running converges; `bao write auth/kubernetes/role/...`
# upserts.

set -euo pipefail

NS=openbao
POD=openbao-0
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"

# Read root token from Secret (same pattern as 05c).
if ! kubectl -n "$NS" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: Secret openbao-root-token-tmp not found in openbao namespace.

Re-create with the main OpenBao root token from 1Password (or mint a
1h admin token via the admin-break-glass role and write it):
  kubectl create secret generic openbao-root-token-tmp -n openbao \
    --from-literal=token=<paste-here>

Delete it after this script completes:
  kubectl delete secret -n openbao openbao-root-token-tmp
EOF
  exit 1
fi
ROOT_TOKEN=$(kubectl -n "$NS" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)

bao() {
  kubectl exec -n "$NS" "$POD" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# Format: role_name | sa_namespace | sa_name | token_policies | token_ttl | token_max_ttl
# Order: app VSO roles first, then per-app audit-signer roles.
APP_ROLES=(
  "control-vso|control|control-vso|vso|3600|86400"
  "member-hub-vso|member-hub|member-hub-vso|vso|3600|86400"
  "member-hub-audit-signer|member-hub|member-hub-audit-signer|audit-signer|900|1800"
  # keycloak-ghcr-vso: lets the keycloak ns VSO binding render ghcr-pull-secret
  # (private image pull cred) via the scoped keycloak-ghcr policy. See
  # manifests/openbao/policies/keycloak-ghcr.hcl + manifests/keycloak/03b-ghcr-vso-binding.yaml.
  "keycloak-ghcr-vso|keycloak|keycloak-ghcr-vso|keycloak-ghcr|3600|86400"
)

echo ">>> Creating app-level kubernetes-auth roles"
for row in "${APP_ROLES[@]}"; do
  IFS='|' read -r ROLE NS_SA SA POL TTL MAX_TTL <<< "$row"
  echo "    $ROLE  (SA: $NS_SA/$SA → policy: $POL, ttl=${TTL}s max=${MAX_TTL}s)"
  bao bao write "auth/kubernetes/role/$ROLE" \
    bound_service_account_names="$SA" \
    bound_service_account_namespaces="$NS_SA" \
    audience="$K8S_AUDIENCE" \
    token_policies="$POL" \
    token_ttl="$TTL" \
    token_max_ttl="$MAX_TTL" \
    alias_name_source="serviceaccount_uid" >/dev/null
done

unset ROOT_TOKEN

cat <<EOF

✓ App-level OpenBao roles applied.

  Roles upserted: ${#APP_ROLES[@]}.
  Add new apps by appending to APP_ROLES in this script.
EOF
