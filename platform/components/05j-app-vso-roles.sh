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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

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
  # platform audit anchor (threat-model X-R1) — signs the OpenBao audit-log chain
  # AND reads its GitHub PAT (secret/platform/audit-anchors-push-token). Two policies:
  # audit-signer (transit/sign) + platform-audit (PAT read). SA in the openbao ns.
  "platform-audit-signer|openbao|platform-audit-signer|audit-signer,platform-audit|900|1800"
  # platform loki audit anchor (threat-model X-R1 Phase 2) — signs the per-namespace
  # Loki window-hash chains AND reads the (shared) GitHub PAT. Same two policies as the
  # openbao anchor; SA lives in the observability ns next to Loki. Manifests:
  # manifests/observability/21-loki-audit-anchor.yaml (applied by 07f-loki.sh).
  "platform-loki-audit-signer|observability|platform-loki-audit-signer|audit-signer,platform-audit|900|1800"
  # proposal-forge (proposalapp) — VSO renders OIDC/SpiceDB/session/Gemini/GSA
  # runtime bundle + ghcr-pull + the proposal-forge-files MinIO key. No
  # audit-signer (PF has no OpenBao Transit usage). Policy paths: vso.hcl
  # apps/proposal-forge/+ , minio/proposal-forge-files , minio/cnpg/credentials.
  "proposal-forge-vso|proposal-forge|proposal-forge-vso|vso|3600|86400"
  # business-manager (managerapp) — VSO renders the OIDC/session/SAM.gov runtime
  # bundle + ghcr-pull. No app MinIO key (no object storage day-1), no SpiceDB
  # PSK (org-tier + RLS authz), no audit-signer (no OpenBao Transit usage).
  # Policy paths: vso.hcl apps/business-manager/+ , minio/cnpg/credentials.
  "business-manager-vso|business-manager|business-manager-vso|vso|3600|86400"
  # keycloak-ghcr-vso: lets the keycloak ns VSO binding render ghcr-pull-secret
  # (private image pull cred) via the scoped keycloak-ghcr policy. See
  # manifests/openbao/policies/keycloak-ghcr.hcl + manifests/keycloak/03b-ghcr-vso-binding.yaml.
  "keycloak-ghcr-vso|keycloak|keycloak-ghcr-vso|keycloak-ghcr|3600|86400"
  # onlyoffice (DOCENG Phase 1) — VSO renders the Document Server's fleet-shared
  # JWT secret (apps/onlyoffice/jwt) into the onlyoffice ns. Consumers (PF,
  # later Control) sync the SAME path via their OWN roles — the vso policy
  # carries their read grant. Policy: manifests/openbao/policies/onlyoffice.hcl.
  "onlyoffice-vso|onlyoffice|onlyoffice-vso|onlyoffice|3600|86400"
  # ecosystem-db (DB-unification P5 — consolidated CNPG cluster) — VSO renders
  # ONLY the barman→MinIO backup creds (secret/minio/cnpg/credentials, granted by
  # the shared `vso` policy, same as every app's CNPG backup-cred read) into the
  # ecosystem-db ns for the cluster's ObjectStore. This ns runs no app, so no
  # app-runtime secrets. (A scoped `ecosystem-db-cnpg` policy granting ONLY
  # minio/cnpg/credentials would be a cleaner least-privilege alternative — add it
  # to 05c + policies/ if preferred; this stub reuses `vso` for fleet consistency.)
  # Applied on the OpenBao break-glass day (GATE A) with the 04-vso-bindings CRs.
  "ecosystem-db-vso|ecosystem-db|ecosystem-db-vso|vso|3600|86400"
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

# ─── Platform audit anchor + verifier (operator-backlog #85 / X-R1) ────────
# Applies the SA, VaultAuth, VaultStaticSecret, NetworkPolicies, ConfigMaps and
# the (SUSPENDED) anchor/verifier CronJobs. Runs here because both VSO (05d, for
# the VaultAuth/VaultStaticSecret CRDs) and the platform-audit-signer role (added
# above) must exist first. No envsubst placeholders → raw apply is safe (same as
# 05b's 06-networkpolicies-main.yaml). The CronJobs stay suspended until the
# operator completes the one-time OpenBao-admin steps — see
# docs/03-runbooks/platform-audit-anchor-activation.md.
M="$PLATFORM_DIR/manifests/openbao"
echo ">>> Applying platform audit anchor + verifier manifests (CronJobs ship suspended)"
kubectl apply -f "$M/12-platform-audit-anchor.yaml"
kubectl apply -f "$M/13-platform-audit-verifier.yaml"

cat <<EOF

✓ App-level OpenBao roles applied.

  Roles upserted: ${#APP_ROLES[@]}.
  Add new apps by appending to APP_ROLES in this script.

  Platform audit anchor + verifier manifests applied (CronJobs SUSPENDED).
  Activate with docs/03-runbooks/platform-audit-anchor-activation.md after
  provisioning the PAT at secret/platform/audit-anchors-push-token.
EOF
