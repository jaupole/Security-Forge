#!/usr/bin/env bash
# kubectl apply wrapper that renders manifest templates via envsubst.
# Usage: apply-manifest.sh [--server-side] <manifest-file> [<manifest-file> ...]
#
# --server-side switches to a server-side apply (with --force-conflicts). Use it
# for a manifest whose live object has a corrupt
# kubectl.kubernetes.io/last-applied-configuration annotation — that annotation
# breaks the client-side 3-way merge, but server-side apply does not use it.
# Currently only the Keycloak CR needs this (operator-backlog #52); client-side
# apply stays the default for everything else.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"

[[ -f "$PLATFORM_DIR/globals.env" ]] || {
  echo "ERR: globals.env not found" >&2
  exit 1
}
set -a
# shellcheck disable=SC1091
source "$PLATFORM_DIR/globals.env"
set +a

APPLY_ARGS=()
if [[ "${1:-}" == "--server-side" ]]; then
  APPLY_ARGS=(--server-side --force-conflicts)
  shift
fi

(( $# > 0 )) || { echo "usage: apply-manifest.sh [--server-side] <file> [file ...]" >&2; exit 1; }

# envsubst allowlist — only substitute named globals, not arbitrary shell vars.
ALLOW='${DOMAIN} ${SPIFFE_TRUST_DOMAIN} ${SPIRE_CLUSTER_NAME} ${LE_ISSUER} ${LE_EMAIL} ${WILDCARD_CERT_NAMESPACE} ${WILDCARD_CERT_SECRET} ${STORAGE_CLASS} ${KEYCLOAK_PLATFORM_REALM} ${KEYCLOAK_TENANTS_REALM} ${TIMEZONE}'

for f in "$@"; do
  [[ -f "$f" ]] || { echo "ERR: file not found: $f" >&2; exit 1; }
  echo ">>> applying $f${APPLY_ARGS:+ (server-side)}"
  envsubst "$ALLOW" < "$f" | kubectl apply "${APPLY_ARGS[@]}" -f -
done
