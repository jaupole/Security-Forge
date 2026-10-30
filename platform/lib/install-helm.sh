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

# ── RBAC-roll guard ───────────────────────────────────────────────────────────
# Helm restarts a workload only when its pod template changes. A chart roll
# that changes RBAC (ClusterRole/Role/*Binding) but NOT the template leaves the
# OLD pod running on OLD permissions until its next unplanned restart. That is
# how VSO broke: the 2026-10-13 roll to chart 1.6.0 dropped the HCP rules from
# the manager ClusterRole while the image stayed 1.4.0; the pod was untouched
# and only crash-looped at its first restart, 17 days later, mid-incident.
# Rule: a chart roll that changes RBAC is followed by a rollout restart of
# every release workload whose template did not change — so the new
# permissions are exercised now, while an operator is watching, not later.
# Set HELM_RBAC_ROLL_GUARD=0 to skip (e.g. bootstrap where nothing runs yet).
GUARD="${HELM_RBAC_ROLL_GUARD:-1}"
_release_filter='.items[] | select(.metadata.annotations["meta.helm.sh/release-name"]==$r)'

rbac_snapshot() {
  {
    kubectl get clusterrole,clusterrolebinding -o json 2>/dev/null \
      | jq -r --arg r "$RELEASE" "$_release_filter"' | "\(.kind)/\(.metadata.name)=\(.metadata.resourceVersion)"'
    kubectl -n "$NS" get role,rolebinding -o json 2>/dev/null \
      | jq -r --arg r "$RELEASE" "$_release_filter"' | "\(.kind)/\(.metadata.name)=\(.metadata.resourceVersion)"'
  } | sort
}

# kind/name=<md5 of pod template> for every release workload in the namespace.
workload_snapshot() {
  kubectl -n "$NS" get deploy,ds,sts -o json 2>/dev/null \
    | jq -r --arg r "$RELEASE" "$_release_filter"' | "\(.kind)/\(.metadata.name)\t\(.spec.template|tojson)"' \
    | while IFS=$'\t' read -r k j; do
        printf '%s=%s\n' "$k" "$(printf '%s' "$j" | md5sum | cut -c1-32)"
      done | sort
}

guard_available() {
  [[ "$GUARD" == "1" ]] && command -v kubectl >/dev/null && command -v jq >/dev/null && kubectl get ns "$NS" >/dev/null 2>&1
}

RBAC_BEFORE="" WORKLOADS_BEFORE=""
if guard_available; then
  RBAC_BEFORE="$(rbac_snapshot)"
  WORKLOADS_BEFORE="$(workload_snapshot)"
fi

echo ">>> helm upgrade --install $RELEASE $CHART (ns=$NS, version=${VERSION:-latest})"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NS" --create-namespace \
  --wait \
  "${HELM_ARGS[@]}"
if guard_available; then
  RBAC_AFTER="$(rbac_snapshot)"
  if [[ "$RBAC_BEFORE" != "$RBAC_AFTER" ]]; then
    echo ">>> RBAC changed in this roll:"
    diff <(echo "$RBAC_BEFORE") <(echo "$RBAC_AFTER") | grep -E '^[<>]' | sed 's/^/    /' || true
    WORKLOADS_AFTER="$(workload_snapshot)"
    restarted=0
    while IFS='=' read -r wl hash; do
      [[ -n "$wl" ]] || continue
      if grep -qxF "$wl=$hash" <<<"$WORKLOADS_AFTER"; then
        kind="${wl%%/*}"; name="${wl#*/}"
        echo ">>> $wl template unchanged — rollout restart so it runs under the new RBAC now"
        kubectl -n "$NS" rollout restart "$kind/$name"
        kubectl -n "$NS" rollout status "$kind/$name" --timeout=300s
        restarted=$((restarted + 1))
      fi
    done <<<"$WORKLOADS_BEFORE"
    echo ">>> RBAC-roll guard: restarted $restarted workload(s)"
  fi
fi
echo "<<< $RELEASE deployed in $NS"
