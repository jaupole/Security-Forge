#!/usr/bin/env bash
# Phase 7b.6 + 7b.7 — apply the weekly secrets-guardrails CronJobs.
#
# Steps:
#   1. (Re)create ConfigMap `secrets-guardrails-verify-scripts` from
#      infrastructure/secrets-guardrails/verify/*.sh — this is what
#      the weekly-guardrail-verify CronJob mounts.
#   2. Apply 01-weekly-guardrail-verify.yaml (CronJob + RBAC).
#   3. Apply 02-weekly-template-drift.yaml (CronJob + RBAC).
#
# Idempotent: re-running picks up edits to the verify scripts (the
# ConfigMap is recreated via dry-run-then-apply) and reconciles the
# CronJob specs.

set -euo pipefail

NS=app
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_DIR="$HERE/../verify"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

green "==> ensure ConfigMap secrets-guardrails-verify-scripts (mount source for weekly-guardrail-verify)"
# Build the --from-file flags into an array so spaces in paths don't
# wreck argv. Each verify script is its own --from-file entry; relative
# names preserve `bash run-all.sh` semantics inside the CronJob.
FROM_FILE_FLAGS=()
while IFS= read -r f; do
    FROM_FILE_FLAGS+=("--from-file=$(basename "$f")=$f")
done < <(find "$VERIFY_DIR" -maxdepth 1 -type f -name '*.sh')

kubectl create configmap secrets-guardrails-verify-scripts \
    --namespace "$NS" \
    "${FROM_FILE_FLAGS[@]}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

green "==> apply 01-weekly-guardrail-verify.yaml"
kubectl apply -f "$HERE/01-weekly-guardrail-verify.yaml"

green "==> apply 02-weekly-template-drift.yaml"
kubectl apply -f "$HERE/02-weekly-template-drift.yaml"

green ""
green "Done. Both CronJobs scheduled in '$NS' ns:"
kubectl get cronjob -n "$NS" -l secforge.platform/component=secrets-guardrails
