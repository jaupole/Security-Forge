#!/usr/bin/env bash
# Helm install/upgrade wrapper:
#   - Sources globals.env so values files can reference ${DOMAIN}, etc.
#   - Renders each values file via envsubst into a temp dir before passing to helm
#   - Adds the chart repo if --repo-name + --repo-url given (idempotent)
#   - Uses `helm upgrade --install` so reruns are safe
#
# Usage:
#   install-helm.sh \
#     --release <name> --namespace <ns> --chart <repo/chart> \
#     [--repo-name <name> --repo-url <url>] \
#     [--version <chart-version>] \
#     [--values <file>] [--values <file> ...] \
#     [--set key=val] [--set key=val ...]
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

RELEASE="" NS="" CHART="" REPO_NAME="" REPO_URL="" VERSION=""
declare -a VALUES=()
declare -a SETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)   RELEASE="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --chart)     CHART="$2"; shift 2 ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --repo-url)  REPO_URL="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --values)    VALUES+=("$2"); shift 2 ;;
    --set)       SETS+=("$2"); shift 2 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 1 ;;
  esac
done

[[ -n "$RELEASE" && -n "$NS" && -n "$CHART" ]] || {
  echo "ERR: --release, --namespace, --chart are required" >&2
  exit 1
}

if [[ -n "$REPO_NAME" && -n "$REPO_URL" ]]; then
  helm repo add "$REPO_NAME" "$REPO_URL" 2>/dev/null || true
  helm repo update "$REPO_NAME" >/dev/null
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

declare -a HELM_ARGS=()

# Build envsubst allowlist of just our globals — prevents envsubst from
# clobbering shell variables like $STATUS / $i / $POD_IP that appear inside
# init-container scripts and other inline YAML.
ALLOW='${DOMAIN} ${SPIFFE_TRUST_DOMAIN} ${SPIRE_CLUSTER_NAME} ${LE_ISSUER} ${LE_EMAIL} ${WILDCARD_CERT_NAMESPACE} ${WILDCARD_CERT_SECRET} ${STORAGE_CLASS} ${KEYCLOAK_PLATFORM_REALM} ${KEYCLOAK_TENANTS_REALM} ${TIMEZONE}'

for v in "${VALUES[@]}"; do
  [[ -f "$v" ]] || { echo "ERR: values file not found: $v" >&2; exit 1; }
  rendered="$TMPDIR/$(basename "$v")"
  envsubst "$ALLOW" < "$v" > "$rendered"
  HELM_ARGS+=(--values "$rendered")
done

for s in "${SETS[@]}"; do
  HELM_ARGS+=(--set "$s")
done

[[ -n "$VERSION" ]] && HELM_ARGS+=(--version "$VERSION")

echo ">>> helm upgrade --install $RELEASE $CHART (ns=$NS, version=${VERSION:-latest})"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NS" --create-namespace \
  --wait \
  "${HELM_ARGS[@]}"
echo "<<< $RELEASE deployed in $NS"
