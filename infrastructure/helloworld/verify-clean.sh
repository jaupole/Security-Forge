#!/usr/bin/env bash
# Phase 9.13 — verify Hello World left no residue.
#
# Runs the eight checks from the Phase 9 prompt § 9.13. Exits 0 if every
# check passes (cluster is clean), 1 otherwise. Each failure is printed
# with the resource(s) that still exist so the operator can re-run
# teardown.sh and identify what got missed.
#
# What is INTENTIONALLY NOT verified here:
#   - The 5-minute Loki soak for "no errors related to dangling Hello World
#     references" — this is operator-time. Run a Loki query for the next
#     5 minutes after teardown:
#       {namespace="app"} |~ "helloworld" |~ "(error|fail)"
#     and confirm no app-tier errors fire. Cluster-tier errors about
#     deleted-but-still-cached objects (e.g., ingress controller dropping
#     old endpoints) are expected briefly.
#
# Auth: BAO_TOKEN with admin policies for the OpenBao checks.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set.\n" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../keycloak/_lib/kcadm-auth.sh
. "$HERE/../keycloak/_lib/kcadm-auth.sh"

NS_APP=app
NS_SPICEDB=spicedb
NS_OPENBAO=openbao
NS_KC=keycloak
KC_POD=keycloak-0
PG_POD=secforge-app-db-1
PG_DB=secforge_app
REALM=secforge-tenants

green() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; FAILED=1; }
hdr()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
FAILED=0

bao_pod() {
    kubectl exec -n "$NS_OPENBAO" openbao-0 -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

kcadm() {
    kubectl exec -n "$NS_KC" "$KC_POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# Authenticate kcadm once for all KC checks below.
kcadm_admin_auth || { red "kcadm auth failed"; FAILED=1; }

# 1. No Hello World workloads in app ns (by part-of label).
hdr "Check 1: K8s workloads with app.kubernetes.io/part-of=helloworld"
RESIDUE=$(kubectl get all -n "$NS_APP" -l app.kubernetes.io/part-of=helloworld -o name 2>/dev/null)
if [ -z "$RESIDUE" ]; then
    green "no workloads found"
else
    red "found:"
    printf '%s\n' "$RESIDUE" >&2
fi

# 2. No Hello World resources by app.kubernetes.io/name (catches the bff
#    that may not have part-of due to original-deployment heritage).
hdr "Check 2: deployments with app.kubernetes.io/name=helloworld-{bff,backend,frontend}"
for NAME in helloworld-bff helloworld-backend helloworld-frontend; do
    if kubectl get deployment -n "$NS_APP" "$NAME" >/dev/null 2>&1; then
        red "deployment $NAME still exists"
    else
        green "deployment $NAME absent"
    fi
done

# 3. helloworld-bff Keycloak client gone.
hdr "Check 3: Keycloak client helloworld-bff in $REALM"
CID=$(kcadm get clients -r "$REALM" -q clientId=helloworld-bff --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -z "$CID" ] || [ "$CID" = "[]" ]; then
    green "client absent"
else
    red "client still exists (id=$CID)"
fi

# 4. Demo users gone (jason/alice/bob/test-bot — NOT jason.upole).
hdr "Check 4: demo users gone (jason/alice/bob/test-bot)"
for USER in jason alice bob test-bot; do
    UID_=$(kcadm get users -r "$REALM" -q "username=$USER" --fields id 2>/dev/null \
        | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
    if [ -z "$UID_" ] || [ "$UID_" = "[]" ]; then
        green "user $USER absent"
    else
        red "user $USER still exists"
    fi
done

# 5. SpiceDB UUID-keyed relationships gone (Phase 4 username-keyed seed
#    is preserved; we only remove the UUID-shaped subjects we added in
#    Phase 9.7's seed-spicedb-uuids.sh).
hdr "Check 5: SpiceDB UUID-keyed relationships under tenant:helloworld + document:welcome"
PSK=$(kubectl get secret -n "$NS_SPICEDB" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d 2>/dev/null || true)
if [ -z "$PSK" ]; then
    red "could not read spicedb PSK; skipping check"
else
    POD="zed-verify-clean-$(date +%s)"
    kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${POD}, namespace: ${NS_SPICEDB}, labels: { role: zed-cli-oneshot } }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: zed
    image: authzed/zed:v1.0.0-debug
    command: ["sleep", "60"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
EOF
    until kubectl get pod -n "$NS_SPICEDB" "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; do
        sleep 1
    done

    UUID_TUPLES=0
    for spec in "tenant:helloworld" "app:helloworld-app" "document:welcome"; do
        OUT=$(kubectl exec -n "$NS_SPICEDB" "$POD" -- zed \
            --endpoint spicedb.spicedb.svc.cluster.local:50051 \
            --token "$PSK" --no-verify-ca \
            relationship read "$spec" 2>/dev/null | grep -v '"level"' || true)
        # Count UUID-shaped subjects (user:xxxxxxxx-…)
        UUID_COUNT=$(printf '%s' "$OUT" | awk '{print $3}' \
            | grep -cE '^user:[0-9a-f]{8}-[0-9a-f]{4}-' || true)
        UUID_TUPLES=$((UUID_TUPLES + UUID_COUNT))
    done

    if [ "$UUID_TUPLES" -eq 0 ]; then
        green "no UUID-keyed relationships remain"
    else
        red "$UUID_TUPLES UUID-keyed tuples still present"
    fi
    # Wait for the zed pod to fully terminate before the platform-health
    # check below, otherwise it shows up as a "non-running pod" — false
    # positive (the pod is gracefully cleaning up).
    kubectl delete pod -n "$NS_SPICEDB" "$POD" --ignore-not-found --wait=true --grace-period=5 >/dev/null 2>&1 || true
fi

# 6. OpenBao paths cleared.
hdr "Check 6: OpenBao policies / JWT roles / DB roles / KV"
for POLICY in helloworld-bff helloworld-backend; do
    if bao_pod bao policy read "$POLICY" >/dev/null 2>&1; then
        red "policy $POLICY still exists"
    else
        green "policy $POLICY absent"
    fi
done
for ROLE in helloworld-bff helloworld-backend; do
    if bao_pod bao read "auth/jwt/role/$ROLE" >/dev/null 2>&1; then
        red "auth/jwt/role/$ROLE still exists"
    else
        green "auth/jwt/role/$ROLE absent"
    fi
done
for ROLE in helloworld-backend-readwrite helloworld-app-readwrite helloworld-app-readonly; do
    if bao_pod bao read "database/roles/$ROLE" >/dev/null 2>&1; then
        red "database/roles/$ROLE still exists"
    else
        green "database/roles/$ROLE absent"
    fi
done
KV_KEYS=$(bao_pod bao kv list -format=json -mount=secret apps 2>/dev/null \
    | jq -r '.[]? | select(test("^helloworld"))' 2>/dev/null || true)
if [ -z "$KV_KEYS" ]; then
    green "secret/apps/helloworld-* paths absent"
else
    red "secret/apps/helloworld-* paths still present:"
    printf '  %s\n' $KV_KEYS >&2
fi

# 7. Postgres helloworld schema + role gone.
hdr "Check 7: Postgres helloworld schema + helloworld_app_owner role"
if kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -tAc "SELECT 1 FROM pg_namespace WHERE nspname='helloworld'" 2>/dev/null | grep -q 1; then
    red "helloworld schema still exists"
else
    green "helloworld schema absent"
fi
if kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -tAc "SELECT 1 FROM pg_roles WHERE rolname='helloworld_app_owner'" 2>/dev/null | grep -q 1; then
    red "helloworld_app_owner role still exists"
else
    green "helloworld_app_owner role absent"
fi

# 8. Container images gone.
hdr "Check 8: container images (docker daemon + containerd)"
DOCKER_HITS=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '^(local/)?helloworld-(backend|bff|frontend)(:|$)' || true)
if [ -z "$DOCKER_HITS" ]; then
    green "no helloworld-* images in docker daemon"
else
    red "still in docker:"
    printf '  %s\n' $DOCKER_HITS >&2
fi
CTR_HITS=$(docker exec desktop-control-plane ctr -n=k8s.io image ls --quiet 2>/dev/null \
    | grep -E "helloworld-(backend|bff|frontend)" || true)
if [ -z "$CTR_HITS" ]; then
    green "no helloworld-* images in containerd k8s.io ns"
else
    red "still in containerd:"
    printf '  %s\n' $CTR_HITS >&2
fi

# Platform-still-healthy spot check (subset of /health-check skill).
hdr "Platform-still-healthy spot check"
for NS_PHASE in keycloak openbao spicedb spire valkey observability istio-system; do
    UNHEALTHY=$(kubectl get pods -n "$NS_PHASE" --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Completed" {print $1, $3}' || true)
    if [ -z "$UNHEALTHY" ]; then
        green "$NS_PHASE: all pods Running/Completed"
    else
        red "$NS_PHASE has non-running pods:"
        printf '  %s\n' "$UNHEALTHY" >&2
    fi
done

# Final summary.
echo
if [ "$FAILED" = "0" ]; then
    printf '\033[32m================================================================\033[0m\n'
    printf '\033[32m   Phase 9.13 verification PASSED. Hello World left no residue.\033[0m\n'
    printf '\033[32m================================================================\033[0m\n'
    echo
    echo "Operator-time follow-up: 5-minute Loki soak. Run this query in"
    echo "Grafana → Loki and confirm no app-tier errors fire over 5 min:"
    echo "  {namespace=\"app\"} |~ \"helloworld\" |~ \"(error|fail)\""
    exit 0
fi
printf '\033[31m================================================================\033[0m\n'
printf '\033[31m   Phase 9.13 verification FAILED. See ✗ marks above.\033[0m\n'
printf '\033[31m   Re-run teardown.sh, then re-run this verifier.\033[0m\n'
printf '\033[31m================================================================\033[0m\n'
exit 1
