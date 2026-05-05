#!/usr/bin/env bash
# Phase 4.5 — verify CheckPermission outcomes match the model + test
# ZedToken consistency.
#
# Approach: spawn ONE long-lived zed pod (5-min sleep), then `kubectl
# exec` into it for each test. Each exec is fast (~0.5s). Avoids the
# Kyverno + scheduler latency of one-pod-per-check.

set -euo pipefail
NS=spicedb
POD=zed-check-runner
PSK=$(kubectl get secret -n "$NS" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)

green() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; FAILED=1; }
hdr()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
FAILED=0

# 1. Spin up a long-lived zed pod we can exec into.
hdr "Spinning up zed runner pod"
kubectl delete pod -n "$NS" "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
# Wait for any prior pod to terminate, otherwise create races.
for i in {1..30}; do
    kubectl get pod -n "$NS" "$POD" >/dev/null 2>&1 || break
    sleep 1
done

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    role: zed-cli-oneshot
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
  # The non-debug authzed/zed image is distroless (no shell), so a
  # `sleep`-based long-runner can't start. The -debug variant ships a
  # busybox shell. We only use it locally for the runbook's interactive
  # checks; production never sees this pod.
  - name: zed
    image: authzed/zed:v1.0.0-debug
    command: ["sleep", "600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
EOF

# Wait for pod Ready.
until kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
    sleep 1
done

trap 'kubectl delete pod -n "$NS" "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

zed() {
    kubectl exec -n "$NS" "$POD" -- zed \
        --endpoint spicedb.spicedb.svc.cluster.local:50051 \
        --token "$PSK" \
        --no-verify-ca \
        "$@"
}

# 2. CheckPermission against the seeded relationships.
hdr "CheckPermission outcomes (Phase 4 seed data)"
check() {
    # $1 resource  $2 perm  $3 subject  $4 expected ALLOWED|DENIED
    local res=$1 perm=$2 subj=$3 want=$4
    local out
    out=$(zed permission check "$res" "$perm" "$subj" 2>&1 | tail -1 | tr -d '\r')
    if [[ "$out" == *"$want"* ]]; then
        green "$res $perm $subj → $out"
    else
        red "$res $perm $subj → $out (want $want)"
    fi
}

# zed v1.0.0 outputs lowercase `true`/`false` rather than ALLOWED/DENIED.
check document:welcome view   user:jason  true     # owner
check document:welcome edit   user:jason  true     # owner
check document:welcome delete user:jason  true     # owner + tenant admin cascade
check document:welcome view   user:alice  true     # explicit viewer (also tenant member cascade)
check document:welcome edit   user:alice  false    # not editor / owner / tenant admin
check document:welcome delete user:alice  false    # not owner / app admin
check document:welcome view   user:bob    false    # no relationship at all

# 3. Cross-tier cascade — tenant admin's authority on a fresh document.
hdr "Cascade — tenant admin on a new document"
# Create a new document that user:jason has NO direct relation to.
# Jason is tenant:helloworld admin; that should cascade through
# app:helloworld-app's `administer` (via tenant->admin) into the
# document's `delete` permission (via app->administer).
#
# Capture the ZedToken from the touch and pass it to the cascade
# checks via --consistency-at-least. Without this, the checks run
# with default `minimize_latency` consistency and may not yet observe
# the just-written relationship — the cascade returns false even
# though the topology supports it. (This isn't a SpiceDB bug; it's
# the contract of the consistency level.)
CASCADE_TOK=$(zed relationship touch document:roadmap app app:helloworld-app --json 2>/dev/null | jq -r '.writtenAt.token')
check_at() {
    # Same as check() but with --consistency-at-least $CASCADE_TOK.
    local res=$1 perm=$2 subj=$3 want=$4
    local out
    out=$(zed permission check "$res" "$perm" "$subj" \
        --consistency-at-least "$CASCADE_TOK" 2>&1 | tail -1 | tr -d '\r')
    if [[ "$out" == *"$want"* ]]; then
        green "$res $perm $subj → $out"
    else
        red "$res $perm $subj → $out (want $want)"
    fi
}
check_at document:roadmap edit   user:jason  true     # tenant admin → app administer → doc edit
check_at document:roadmap delete user:jason  true     # tenant admin → app administer → doc delete
check_at document:roadmap view   user:alice  true     # tenant member → app use → doc view
check_at document:roadmap edit   user:alice  false    # member is not editor

# 4. ZedToken consistency.
#
# Sequence:
#   - WriteRelationships returns a ZedToken (the revision after the write).
#   - Pass that ZedToken to a CheckPermission with `at_least_as_fresh`
#     consistency. The check MUST observe the just-written relationship
#     (otherwise the `at_least_as_fresh` guarantee is broken).
hdr "ZedToken consistency (read-your-writes)"

# Write a fresh relationship and capture the returned ZedToken.
# `zed relationship create` returns the token in the format:
#   GhUKEzE3MTI0MzU2NzgwOTk2NzM3NjA= (or similar base64)
# zed v1.0.0 syntax: `<resource> <relation> <subject>` — three positional args.
WRITE_TOKEN=$(zed relationship create document:fresh owner user:eve --json 2>/dev/null \
    | jq -r '.writtenAt.token')

if [ -z "$WRITE_TOKEN" ] || [ "$WRITE_TOKEN" = "null" ]; then
    red "Failed to capture ZedToken from write"
else
    green "Wrote document:fresh#owner@user:eve, ZedToken=${WRITE_TOKEN:0:32}…"

    # Now check with explicit at_least_as_fresh against that token.
    # zed exposes the consistency option via `--consistency-at-least-as-fresh`.
    out=$(zed permission check document:fresh edit user:eve \
        --consistency-at-least "$WRITE_TOKEN" 2>&1 | tail -1 | tr -d '\r')
    if [[ "$out" == *"true"* ]]; then
        green "at_least_as_fresh check sees the just-written relationship → $out"
    else
        red "at_least_as_fresh check did not observe the write → $out"
    fi
fi

# Clean up the test relationships we added so re-runs are deterministic.
hdr "Cleanup"
zed relationship delete document:fresh owner user:eve >/dev/null 2>&1 || true
zed relationship delete document:roadmap app app:helloworld-app >/dev/null 2>&1 || true
green "Removed test-only relationships (the original Phase 4.4 seed remains)"

# Final summary.
echo
if [ "$FAILED" = "0" ]; then
    printf '\033[32m== ALL CHECKS PASSED ==\033[0m\n'
    exit 0
fi
printf '\033[31m== FAILURES ABOVE ==\033[0m\n'
exit 1
