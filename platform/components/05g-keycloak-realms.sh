#!/usr/bin/env bash
# 05g — Apply Keycloak realms.
#
# Imports BOTH realms in one pass:
#   - `platform`         — operators / staff scope
#   - `secforge-tenants` — SaaS customer tenant scope (Shape B realm
#                          split, see plan
#                          ~/.claude/plans/so-for-the-current-polymorphic-thompson.md
#                          and docs/01-architecture/01-iam-platform.md)
#
# The Keycloak operator's realm-import job is idempotent on the realm
# name: if a realm already exists, the import is a no-op (no
# destructive update). To update an existing realm, use kcadm.sh — not
# by re-running this script.
#
# Idempotent at the manifest layer (kubectl apply).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
REALMS_DIR="$PLATFORM_DIR/manifests/keycloak/realms"

# apply_realm <yaml-file> <realm-import-cr-name> <human-realm-name>
#
# Applies a KeycloakRealmImport manifest and waits up to 3 minutes for
# the operator to mark Done=True. Fatal-exits on timeout so a broken
# import does not silently leave the next component to fail downstream.
apply_realm() {
  local yaml="$1"
  local cr_name="$2"
  local realm_label="$3"

  echo ""
  echo ">>> Applying KeycloakRealmImport for the $realm_label realm"
  "$LIB/apply-manifest.sh" "$yaml"

  echo ">>> Waiting for the operator to import the $realm_label realm (~30-90s)"
  local status=""
  for _ in {1..60}; do
    status=$(kubectl -n keycloak get keycloakrealmimport "$cr_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "")
    if [[ "$status" == "True" ]]; then
      echo "    $realm_label realm import Done=True"
      return 0
    fi
    sleep 3
  done

  echo "ERROR: $realm_label realm import did not complete within 3 minutes." >&2
  echo "       Inspect: kubectl -n keycloak describe keycloakrealmimport $cr_name" >&2
  exit 1
}

apply_realm "$REALMS_DIR/platform-realm.yaml"         "platform-realm-import"         "platform"
apply_realm "$REALMS_DIR/secforge-tenants-realm.yaml" "secforge-tenants-realm-import" "secforge-tenants"

cat <<'EOF'

✓ Both realms imported.

Verify each realm is reachable:
  curl -s https://auth.secforge.dev/realms/platform/.well-known/openid-configuration | jq -r .issuer
  curl -s https://auth.secforge.dev/realms/secforge-tenants/.well-known/openid-configuration | jq -r .issuer

Next steps:
  1. Run 03a-keycloak-realm-hardening.sh to apply the custom auth flow + drift
     guards to both realms. (Realm-import handles most policy; 03a is the
     idempotent safety net for the custom WebAuthn flow.)
  2. Create your operator admin user in the `platform` realm via the Keycloak
     admin UI (passkey enrollment required at first login).
  3. Tenant users are created later via the Portal signup wizard (Keycloak
     Admin API → secforge-tenants realm). No manual setup needed here.
EOF
