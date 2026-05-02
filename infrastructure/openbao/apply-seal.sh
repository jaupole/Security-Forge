#!/usr/bin/env bash
# Phase 5.2 — deploy openbao-seal.
#
# Pre-condition: openbao Helm repo added (`helm repo add openbao
# https://openbao.github.io/openbao-helm`).
#
# Steps:
#   1. Apply ServiceAccounts and Certificates.
#   2. Apply NetworkPolicies (default-deny + targeted allows).
#   3. Helm install openbao-seal in `openbao` ns.
#   4. Wait for the StatefulSet pod to be Ready (Ready=true even when
#      sealed, because the readiness probe accepts sealedcode=204).
#   5. Print next-step instructions for init.
#
# Idempotent: re-running upgrades the Helm release in place.

set -euo pipefail
NS=openbao
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { printf 'missing: %s\n' "$1" >&2; exit 1; }; }
require_cmd kubectl
require_cmd helm

green "==> Applying ServiceAccounts + Certificates"
kubectl apply -f "$HERE/01-serviceaccounts.yaml"
kubectl apply -f "$HERE/02-certificates.yaml"

green "==> Applying NetworkPolicies (seal)"
kubectl apply -f "$HERE/05-networkpolicies-seal.yaml"

green "==> Helm install/upgrade openbao-seal"
helm upgrade --install openbao-seal openbao/openbao \
    --namespace "$NS" \
    --version 0.27.2 \
    --values "$HERE/03-openbao-seal-values.yaml" \
    --wait \
    --timeout 5m

green "==> Waiting for openbao-seal-0 to be Ready (sealed is OK)"
kubectl -n "$NS" rollout status statefulset/openbao-seal --timeout=180s

green ""
green "openbao-seal is up but SEALED. Next step:"
green "  bash infrastructure/openbao/init-seal.sh"
green ""
green "init-seal.sh will:"
green "  - run 'bao operator init -key-shares=5 -key-threshold=3'"
green "  - print the 5 unseal keys + initial root token to STDOUT once"
green "  - unseal the seal-OpenBao with 3 of the 5 keys"
green "  - enable Transit and create the 'unseal' key"
green "  - create unseal-policy + a periodic (period=720h) token for main OpenBao"
green ""
green "BEFORE running init-seal.sh: be ready to copy 5 keys + 2 tokens"
green "into your offline password manager."
