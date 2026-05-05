#!/usr/bin/env bash
# Phase 9.7 — apply helloworld-frontend manifests in order.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

green "==> 01-configmap.sh (rebuilds the ConfigMap from index.html/app.js/style.css)"
bash "$HERE/01-configmap.sh"

green "==> apply 02-deployment.yaml"
kubectl apply -f "$HERE/02-deployment.yaml"

green "==> apply 03-service.yaml"
kubectl apply -f "$HERE/03-service.yaml"

green ""
green "Waiting for rollout..."
kubectl rollout status -n app deployment/helloworld-frontend --timeout=120s
green ""
green "helloworld-frontend deployed."
