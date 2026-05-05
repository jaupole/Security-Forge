#!/usr/bin/env bash
# Phase 9.3 — verify the SpiceDB access matrix for the Hello World demo.
#
# The 6 relationships Phase 9 needs were already seeded in Phase 4 (see
# infrastructure/spicedb/seed-test-data.yaml). This script does NOT
# re-seed; it only verifies the resulting access matrix.
#
# If a check fails, re-apply Phase 4's seed first:
#   bash infrastructure/spicedb/seed-test-data.sh
#
# Architecture: docs/01-architecture/10-helloworld-demo.md § Permission model.

set -euo pipefail
NS=spicedb
POD="zed-helloworld-verify-$(date +%s)"

green() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; FAILED=1; }
hdr()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
FAILED=0

# Phase 6.10b moved the spicedb config secret name; this script uses the
# VSO-rendered name. If the future cloud-edition migration renames it
# back, the only change here is this jsonpath.
PSK=$(kubectl get secret -n "$NS" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)

hdr "Spinning up zed runner pod"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    role: zed-cli-oneshot
    secforge.platform/component: helloworld-verify
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
  - name: zed
    image: authzed/zed:v1.0.0-debug
    command: ["sleep", "180"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
EOF

trap 'kubectl delete pod -n "$NS" "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

until kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
    sleep 1
done

zed() {
    kubectl exec -n "$NS" "$POD" -- zed \
        --endpoint spicedb.spicedb.svc.cluster.local:50051 \
        --token "$PSK" \
        --no-verify-ca \
        "$@"
}

check() {
    local res=$1 perm=$2 subj=$3 want=$4
    local out
    # zed prints the bool answer first, then a version-check warning.
    # Filter out anything that looks like a JSON warning so we just see
    # the answer.
    out=$(zed permission check "$res" "$perm" "$subj" 2>&1 \
        | grep -v '"level":"warn"' \
        | tail -1 | tr -d '\r')
    if [[ "$out" == *"$want"* ]]; then
        green "$res $perm $subj → $out"
    else
        red "$res $perm $subj → $out (want $want)"
    fi
}

hdr "Phase 9.3 access matrix — document:welcome"
check document:welcome view user:jason true     # owner
check document:welcome edit user:jason true     # owner
check document:welcome view user:alice true     # explicit viewer
check document:welcome edit user:alice false    # not editor / owner
check document:welcome view user:bob   false    # no relationship
check document:welcome edit user:bob   false    # no relationship

echo
if [ "$FAILED" = "0" ]; then
    printf '\033[32m== ALL 6 CHECKS PASSED ==\033[0m\n'
    exit 0
fi
printf '\033[31m== FAILURES ABOVE — re-seed via infrastructure/spicedb/seed-test-data.sh ==\033[0m\n'
exit 1
