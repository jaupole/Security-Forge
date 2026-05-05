#!/usr/bin/env bash
# Phase 9.7 — add UUID-keyed companion SpiceDB relationships.
#
# WHY: Phase 4's seed (`infrastructure/spicedb/seed-test-data.yaml`) keys
# users by username — `user:jason`, `user:alice`, `user:bob`. The Keycloak
# `sub` claim is a UUID, not a username, and `apps/lib/api-auth.Claims`
# only surfaces `sub`. Rather than modify the api-auth library to expose
# `preferred_username`, we add a parallel set of UUID-keyed tuples that
# mirror the Phase 4 access matrix exactly.
#
# After this script runs:
#   user:<jason-uuid>    → owner of document:welcome
#   user:<alice-uuid>    → viewer + tenant member
#   user:<bob-uuid>      → no relationships (denied)
#   tenant:helloworld#admin@user:<jason-uuid>
#   tenant:helloworld#member@user:<alice-uuid>
#   app:helloworld-app#user@user:<alice-uuid>
#   document:welcome#owner@user:<jason-uuid>
#   document:welcome#viewer@user:<alice-uuid>
#
# Phase 9.12 teardown removes ONLY the UUID-keyed tuples; the Phase 4
# username-keyed tuples are preserved (other test fixtures depend on them).
#
# Auth (per ADR-0022): set BAO_TOKEN to an OpenBao admin token so
# kcadm-auth.sh can fetch the kcadm-admin client_secret.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. See infrastructure/helloworld/provision-db-and-bao.sh header.\n" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../keycloak/_lib/kcadm-auth.sh
. "$HERE/../keycloak/_lib/kcadm-auth.sh"

NS_KC=keycloak
KC_POD=keycloak-0
NS_SPICEDB=spicedb
REALM=secforge-tenants

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Authenticate kcadm.
kcadm_admin_auth || exit 1

# 2. Resolve UUIDs via kcadm.
fetch_uuid() {
    local username="$1"
    kubectl exec -n "$NS_KC" "$KC_POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh get users -r "$REALM" -q "username=$username" --fields id 2>/dev/null \
        | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/'
}

JASON_ID=$(fetch_uuid jason)
ALICE_ID=$(fetch_uuid alice)
BOB_ID=$(fetch_uuid bob)

if [ -z "$JASON_ID" ] || [ -z "$ALICE_ID" ] || [ -z "$BOB_ID" ]; then
    red "could not resolve all three UUIDs (jason=$JASON_ID alice=$ALICE_ID bob=$BOB_ID)"
    red "Run infrastructure/helloworld/create-users.sh first."
    exit 1
fi

green "==> resolved UUIDs"
green "    jason: $JASON_ID"
green "    alice: $ALICE_ID"
green "    bob:   $BOB_ID"

# 3. Spin up a one-shot zed pod and write the tuples with TOUCH semantics.
PSK=$(kubectl get secret -n "$NS_SPICEDB" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d)
POD="zed-helloworld-uuids-$(date +%s)"

green "==> spinning up zed pod $POD"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS_SPICEDB}
  labels:
    role: zed-cli-oneshot
    app.kubernetes.io/part-of: helloworld
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

trap 'kubectl delete pod -n "$NS_SPICEDB" "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

until kubectl get pod -n "$NS_SPICEDB" "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
    sleep 1
done

zed() {
    kubectl exec -n "$NS_SPICEDB" "$POD" -- zed \
        --endpoint spicedb.spicedb.svc.cluster.local:50051 \
        --token "$PSK" \
        --no-verify-ca \
        "$@"
}

green "==> writing UUID-keyed tuples (TOUCH; idempotent)"
# zed v1.0.0 syntax: <resource:id> <relation> <subject:id>
zed relationship touch "tenant:helloworld"  admin  "user:$JASON_ID" >/dev/null
zed relationship touch "tenant:helloworld"  member "user:$ALICE_ID" >/dev/null
zed relationship touch "app:helloworld-app" user   "user:$ALICE_ID" >/dev/null
zed relationship touch "document:welcome"   owner  "user:$JASON_ID" >/dev/null
zed relationship touch "document:welcome"   viewer "user:$ALICE_ID" >/dev/null
green "    5 tuples touched"

green "==> verifying access matrix on UUID-keyed users"
check() {
    local res=$1 perm=$2 subj=$3 want=$4
    local out
    out=$(zed permission check "$res" "$perm" "$subj" 2>&1 | grep -v '"level":"warn"' | tail -1 | tr -d '\r')
    if [[ "$out" == *"$want"* ]]; then
        printf '\033[32m  ✓ %s %s %s → %s\033[0m\n' "$res" "$perm" "$subj" "$out"
    else
        printf '\033[31m  ✗ %s %s %s → %s (want %s)\033[0m\n' "$res" "$perm" "$subj" "$out" "$want" >&2
        return 1
    fi
}

FAIL=0
check document:welcome view "user:$JASON_ID" true  || FAIL=1
check document:welcome edit "user:$JASON_ID" true  || FAIL=1
check document:welcome view "user:$ALICE_ID" true  || FAIL=1
check document:welcome edit "user:$ALICE_ID" false || FAIL=1
check document:welcome view "user:$BOB_ID"   false || FAIL=1
check document:welcome edit "user:$BOB_ID"   false || FAIL=1

if [ "$FAIL" = "0" ]; then
    green ""
    green "Phase 9.7 SpiceDB UUID seeding complete."
    exit 0
fi
red "verification failed"
exit 1
