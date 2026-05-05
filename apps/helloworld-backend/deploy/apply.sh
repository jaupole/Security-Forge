#!/usr/bin/env bash
# Phase 9.7 — apply helloworld-backend manifests in order.
#
# Pre-conditions:
#   - Image helloworld-backend:0.1.0 built and present in Docker Desktop's
#     image store (see ../build.sh).
#   - Phase 9.4a provisioning ran (DB schema + OpenBao role + JWT auth role).
#   - The shared spicedb-creds-vso Secret + spicedb-ca-bundle ConfigMap
#     exist (rendered by Phase 6.10b VSO cutover).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

green "==> apply 01-spiffe-helper-conf.yaml"
kubectl apply -f "$HERE/01-spiffe-helper-conf.yaml"

green "==> apply 02-deployment.yaml (ServiceAccount + Deployment)"
kubectl apply -f "$HERE/02-deployment.yaml"

green "==> apply 03-service.yaml"
kubectl apply -f "$HERE/03-service.yaml"

green "==> apply 04-authorizationpolicy.yaml"
kubectl apply -f "$HERE/04-authorizationpolicy.yaml"

green "==> apply 05-networkpolicy.yaml"
kubectl apply -f "$HERE/05-networkpolicy.yaml"

green ""
green "Waiting for rollout..."
kubectl rollout status -n app deployment/helloworld-backend --timeout=180s
green ""
green "helloworld-backend deployed."
