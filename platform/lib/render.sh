#!/usr/bin/env bash
# Render a template file by substituting ${VAR} placeholders from globals.env.
# Usage: render.sh <input-file>  -> rendered content on stdout
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

[[ -f "$PLATFORM_DIR/globals.env" ]] || {
  echo "ERR: globals.env not found at $PLATFORM_DIR/globals.env" >&2
  exit 1
}

set -a
# shellcheck disable=SC1091
source "$PLATFORM_DIR/globals.env"
set +a

input="${1:?usage: render.sh <input-file>}"
[[ -f "$input" ]] || { echo "ERR: file not found: $input" >&2; exit 1; }

# envsubst allowlist — only substitute named globals, not arbitrary shell vars.
# A bare envsubst blanks $vars inside embedded container scripts (e.g. the
# OpenBao raft-snapshot and guardrail-selftest CronJobs). Keep this list
# identical to apply-manifest.sh so rendered previews match what gets applied.
ALLOW='${DOMAIN} ${SPIFFE_TRUST_DOMAIN} ${SPIRE_CLUSTER_NAME} ${LE_ISSUER} ${LE_EMAIL} ${WILDCARD_CERT_NAMESPACE} ${WILDCARD_CERT_SECRET} ${STORAGE_CLASS} ${KEYCLOAK_PLATFORM_REALM} ${KEYCLOAK_TENANTS_REALM} ${TIMEZONE} ${PUBLIC_IP} ${TAILNET_IP}'

envsubst "$ALLOW" < "$input"
