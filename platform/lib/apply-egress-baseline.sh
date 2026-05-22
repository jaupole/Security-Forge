#!/usr/bin/env bash
# apply-egress-baseline.sh — apply the egress baseline NPs to a namespace.
#
# Renders platform/manifests/_egress-baseline/baseline.yaml.tpl with the
# given namespace name and applies. Idempotent (kubectl apply).
#
# Usage:
#   apply-egress-baseline.sh <namespace>
#
# What it deploys:
#   - NetworkPolicy default-deny-egress  (empty rules; locks every pod)
#   - NetworkPolicy allow-egress-essentials (DNS + K8s API; layered allow)
#
# Workload-specific allows (e.g., service-to-service in-cluster, public
# 443 for cert-manager) MUST be authored separately as
# platform/manifests/<ns>/0X-egress-<purpose>.yaml and applied via
# apply-manifest.sh.
#
# Pre-condition: the namespace must already exist.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <namespace>" >&2
  exit 1
fi

NS="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
TPL="$PLATFORM_DIR/manifests/_egress-baseline/baseline.yaml.tpl"

if [ ! -f "$TPL" ]; then
  echo "ERROR: template not found at $TPL" >&2
  exit 1
fi

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "ERROR: namespace $NS does not exist" >&2
  exit 1
fi

echo ">>> applying egress baseline to ns/$NS"
NS="$NS" envsubst < "$TPL" | kubectl apply -f -
