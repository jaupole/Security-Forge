#!/usr/bin/env bash
# 05g — Apply Keycloak realms.
#
# Imports the `platform` realm (operators / system-admin scope). The
# `secforge-tenants` realm (end-user / tenant scope) is deferred until apps
# deploy.
#
# The Keycloak operator's realm-import job is idempotent on the realm name:
# if `platform` already exists, the import is a no-op (no destructive update).
# To update an existing realm, use kcadm.sh — not by re-running this script.
#
# Idempotent at the manifest layer (kubectl apply).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

echo ">>> Applying KeycloakRealmImport for the platform realm"
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/keycloak/realms/platform-realm.yaml"

echo ">>> Waiting for the operator to import the realm (~30-90s)"
for _ in {1..60}; do
  status=$(kubectl -n keycloak get keycloakrealmimport platform-realm-import -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "")
  if [[ "$status" == "True" ]]; then
    echo "    realm import Done=True"
    break
  fi
  sleep 3
done

if [[ "$status" != "True" ]]; then
  echo "ERROR: realm import did not complete within 3 minutes." >&2
  echo "       Inspect: kubectl -n keycloak describe keycloakrealmimport platform-realm-import" >&2
  exit 1
fi

cat <<'EOF'

✓ Platform realm imported.

Verify the realm is reachable:
  curl -s https://auth.secforge.dev/realms/platform/.well-known/openid-configuration | jq -r .issuer

Next manual step:
  Create a platform admin user with TOTP via the Keycloak admin UI.
  See instructions in the next message.
EOF
