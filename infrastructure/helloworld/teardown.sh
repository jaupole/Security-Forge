#!/usr/bin/env bash
# Phase 9.12 — tear down Hello World.
#
# Hello World existed to prove the platform works (per
# docs/01-architecture/10-helloworld-demo.md). The 9.10.5 checkpoint
# passed 2026-05-04; this script reverses the deploy so Phase 10 starts
# on a clean cluster. The reference *source code* under
# apps/helloworld-frontend/, apps/helloworld-backend/, apps/helloworld-bff/
# stays in the tree as the integration pattern Phase 10 forks from.
#
# Idempotent: safe to re-run. Each delete uses --ignore-not-found or
# equivalent. Final summary lists everything actually removed in this run.
#
# Auth (per ADR-0022): set BAO_TOKEN to an OpenBao admin token so kcadm
# auth + bao operations work. See infrastructure/helloworld/provision-db-and-bao.sh
# header for how to obtain it (`bao login -method=oidc role=admin`).
#
# What is REMOVED:
#   K8s/app:
#     - Deployments: helloworld-backend, helloworld-bff, helloworld-frontend
#     - Services + ServiceAccounts of the same
#     - ConfigMaps: helloworld-frontend, helloworld-frontend-nginx-conf,
#                   helloworld-backend-spiffe-helper, helloworld-bff-spiffe-helper
#     - Secrets: bff-jwt-helloworld-bff (legacy K8s Secret pre-VSO; safe to
#                  drop because OpenBao is now authoritative per Phase 6.10b)
#     - ServiceMonitors: helloworld-backend, helloworld-bff
#     - Ingress: helloworld-bff (the app.secforge.local route)
#     - AuthorizationPolicies: allow-bff-to-helloworld-backend,
#                              allow-prometheus-to-helloworld-backend-metrics
#     - NetworkPolicies (in app ns): allow-helloworld-bff-to-helloworld-backend,
#                                    allow-helloworld-backend-egress,
#                                    allow-helloworld-bff-to-helloworld-frontend,
#                                    allow-helloworld-bff-egress,
#                                    allow-ingress-nginx-to-helloworld-bff,
#                                    allow-helloworld-backend-to-secforge-app-db
#     - NetworkPolicies (in spicedb ns): allow-helloworld-backend-to-spicedb
#
#   Keycloak (secforge-tenants realm):
#     - Client: helloworld-bff
#     - Client scope: helloworld-api (and its audience-mapper)
#     - Users: jason, alice, bob, test-bot
#         (NOT jason.upole — that's the operator's admin user, different ns)
#         (NOT proposal-forge-bff/project-tracker-bff/pm-bff clients —
#          Phase 10 needs those)
#
#   SpiceDB (running cluster):
#     - UUID-keyed relationships from infrastructure/helloworld/seed-spicedb-uuids.sh
#       (the username-keyed Phase 4 seed in infrastructure/spicedb/seed-test-data.yaml
#        STAYS — it's part of the broader fixture and check-permissions.sh depends
#        on it)
#
#   OpenBao:
#     - Policy: helloworld-backend
#     - JWT auth role: helloworld-backend
#     - Postgres dynamic role: database/roles/helloworld-backend-readwrite
#     - Active leases on that role (revoked)
#     - allowed_roles on database/config/secforge-app: helloworld-backend-readwrite
#       removed from the list (helloworld-app-readwrite + helloworld-app-readonly
#       stay because the BFF originally was wired to use them via apps/lib/secrets,
#       and the templated app-template.hcl pattern keeps `database/creds/<app>-*`
#       open for future use)
#     - secret/data/apps/helloworld-* paths (none currently; defensive sweep)
#
#   Postgres (secforge_app DB):
#     - Schema helloworld (CASCADE — drops documents table + seed row)
#     - Static role helloworld_app_owner
#
#   Container images (docker daemon + containerd k8s.io):
#     - helloworld-backend:* and local/helloworld-backend:*
#     - helloworld-frontend:* (none — frontend is just nginx + ConfigMap, no
#       custom image was built)
#     - helloworld-bff image STAYS (codebase is the reference for Phase 10)
#
# What is PRESERVED:
#   - apps/helloworld-{frontend,backend,bff}/ source trees (reference)
#   - apps/lib/api-auth/ + apps/lib/secrets/ + apps/lib/authzn/ (platform libs)
#   - The four Phase 1 Postgres databases (secforge_app stays; only the
#     helloworld schema in it goes)
#   - The platform itself: Keycloak, SpiceDB, OpenBao, SPIRE, Istio,
#     observability stack, MinIO, Valkey, Teleport
#   - The proposal-forge-bff / project-tracker-bff / pm-bff Keycloak clients
#   - The Phase 4 SpiceDB seed (username-keyed tuples)
#   - All ADRs, runbooks, and architecture docs
#   - kvadm-admin client + its OpenBao secret (Phase 3 follow-up)
#
# Usage:
#   BAO_TOKEN=$(cat ~/.bao-token) bash infrastructure/helloworld/teardown.sh
#
# Re-run safety:
#   Each step uses kubectl delete --ignore-not-found, kcadm get-then-delete
#   guards, bao operations that no-op on missing keys, and Postgres DROP IF
#   EXISTS. A second run prints "(already absent)" for items the first run
#   removed.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set.\n" >&2
    printf "Get one with: bao login -method=oidc role=admin\n" >&2
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

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Track what was actually removed for the final summary.
REMOVED_TALLY=()
record() { REMOVED_TALLY+=("$1"); }

bao_pod() {
    kubectl exec -n "$NS_OPENBAO" openbao-0 -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

kcadm() {
    kubectl exec -n "$NS_KC" "$KC_POD" -c keycloak -- \
        /opt/keycloak/bin/kcadm.sh "$@"
}

# ─── Section 1 — K8s workloads in `app` ──────────────────────────────────
green "==> [1/8] k8s: helloworld deployments + their satellites in app ns"

for DEPLOY in helloworld-backend helloworld-bff helloworld-frontend; do
    if kubectl get deployment -n "$NS_APP" "$DEPLOY" >/dev/null 2>&1; then
        kubectl delete deployment -n "$NS_APP" "$DEPLOY" --ignore-not-found --wait=false 2>&1 | tail -1
        record "Deployment app/$DEPLOY"
    fi
done

for SVC in helloworld-backend helloworld-bff helloworld-frontend; do
    if kubectl get svc -n "$NS_APP" "$SVC" >/dev/null 2>&1; then
        kubectl delete svc -n "$NS_APP" "$SVC" --ignore-not-found 2>&1 | tail -1
        record "Service app/$SVC"
    fi
done

for SA in helloworld-backend helloworld-bff; do
    if kubectl get sa -n "$NS_APP" "$SA" >/dev/null 2>&1; then
        kubectl delete sa -n "$NS_APP" "$SA" --ignore-not-found 2>&1 | tail -1
        record "ServiceAccount app/$SA"
    fi
done

for CM in helloworld-frontend helloworld-frontend-nginx-conf helloworld-backend-spiffe-helper helloworld-bff-spiffe-helper; do
    if kubectl get cm -n "$NS_APP" "$CM" >/dev/null 2>&1; then
        kubectl delete cm -n "$NS_APP" "$CM" --ignore-not-found 2>&1 | tail -1
        record "ConfigMap app/$CM"
    fi
done

# Pre-VSO BFF Secret (Phase 6.10b deleted these already in real life, but a
# defensive sweep here costs nothing — name pattern is bff-jwt-helloworld-bff).
if kubectl get secret -n "$NS_APP" bff-jwt-helloworld-bff >/dev/null 2>&1; then
    kubectl delete secret -n "$NS_APP" bff-jwt-helloworld-bff --ignore-not-found 2>&1 | tail -1
    record "Secret app/bff-jwt-helloworld-bff (pre-VSO; no-op if Phase 6.10b removed it)"
fi

for SM in helloworld-backend helloworld-bff; do
    if kubectl get servicemonitor -n "$NS_APP" "$SM" >/dev/null 2>&1; then
        kubectl delete servicemonitor -n "$NS_APP" "$SM" --ignore-not-found 2>&1 | tail -1
        record "ServiceMonitor app/$SM"
    fi
done

if kubectl get ingress -n "$NS_APP" helloworld-bff >/dev/null 2>&1; then
    kubectl delete ingress -n "$NS_APP" helloworld-bff --ignore-not-found 2>&1 | tail -1
    record "Ingress app/helloworld-bff (app.secforge.local)"
fi

# ─── Section 2 — K8s policies (Authz + Network) ─────────────────────────
green "==> [2/8] k8s: AuthorizationPolicies + NetworkPolicies"

for AP in allow-bff-to-helloworld-backend allow-prometheus-to-helloworld-backend-metrics; do
    if kubectl get authorizationpolicy -n "$NS_APP" "$AP" >/dev/null 2>&1; then
        kubectl delete authorizationpolicy -n "$NS_APP" "$AP" --ignore-not-found 2>&1 | tail -1
        record "AuthorizationPolicy app/$AP"
    fi
done

for NP in allow-helloworld-bff-to-helloworld-backend \
          allow-helloworld-backend-egress \
          allow-helloworld-bff-to-helloworld-frontend \
          allow-helloworld-bff-egress \
          allow-ingress-nginx-to-helloworld-bff \
          allow-helloworld-backend-to-secforge-app-db; do
    if kubectl get networkpolicy -n "$NS_APP" "$NP" >/dev/null 2>&1; then
        kubectl delete networkpolicy -n "$NS_APP" "$NP" --ignore-not-found 2>&1 | tail -1
        record "NetworkPolicy app/$NP"
    fi
done

if kubectl get networkpolicy -n "$NS_SPICEDB" allow-helloworld-backend-to-spicedb >/dev/null 2>&1; then
    kubectl delete networkpolicy -n "$NS_SPICEDB" allow-helloworld-backend-to-spicedb --ignore-not-found 2>&1 | tail -1
    record "NetworkPolicy spicedb/allow-helloworld-backend-to-spicedb"
fi

# Valkey-related NetworkPolicy in valkey ns (BFF was a valkey-client; the
# NetworkPolicy in valkey ns is keyed off the `valkey-client: "true"` label
# which is on the BFF pod template — when the deployment is deleted the
# label-based ingress allow falls quiet automatically; nothing to delete here.

# ─── Section 3 — Keycloak users + client + scope ────────────────────────
green "==> [3/8] keycloak: client, scope, users in $REALM"

kcadm_admin_auth || { red "kcadm auth failed; aborting Keycloak teardown"; exit 1; }

# Client scope helloworld-api (Phase 9 added).
SCOPE_ID=$(kcadm get client-scopes -r "$REALM" --query name=helloworld-api --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -n "$SCOPE_ID" ] && [ "$SCOPE_ID" != "[]" ]; then
    kcadm delete "client-scopes/$SCOPE_ID" -r "$REALM" 2>&1 | tail -1
    record "Keycloak client-scope $REALM/helloworld-api"
fi

# Client helloworld-bff. (Mappers on it die with the client.)
CLIENT_ID=$(kcadm get clients -r "$REALM" -q clientId=helloworld-bff --fields id 2>/dev/null \
    | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "[]" ]; then
    kcadm delete "clients/$CLIENT_ID" -r "$REALM" 2>&1 | tail -1
    record "Keycloak client $REALM/helloworld-bff"
fi

# Users: jason / alice / bob / test-bot. NOT jason.upole.
for USER in jason alice bob test-bot; do
    USER_ID=$(kcadm get users -r "$REALM" -q "username=$USER" --fields id 2>/dev/null \
        | tr -d ' \r\n' | sed -E 's/.*"id":"([^"]+)".*/\1/')
    if [ -n "$USER_ID" ] && [ "$USER_ID" != "[]" ]; then
        kcadm delete "users/$USER_ID" -r "$REALM" 2>&1 | tail -1
        record "Keycloak user $REALM/$USER"
    fi
done

# ─── Section 4 — SpiceDB UUID-keyed relationships ───────────────────────
green "==> [4/8] spicedb: UUID-keyed Phase 9 relationships"

# We don't know which UUIDs were seeded once the Keycloak users are deleted
# above. Strategy: spin up a zed pod and delete by relation+resource pattern,
# scoped to user:* subjects. The Phase 4 username-keyed (user:jason etc.)
# tuples stay because we filter to subjects whose ID looks like a UUID
# (contains a hyphen-after-position-8, which usernames do not).
PSK=$(kubectl get secret -n "$NS_SPICEDB" spicedb-config-vso -o jsonpath='{.data.preshared_key}' | base64 -d 2>/dev/null || true)
if [ -n "$PSK" ]; then
    POD="zed-helloworld-teardown-$(date +%s)"
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
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: zed
    image: authzed/zed:v1.0.0-debug
    command: ["sleep", "120"]
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

    zed_exec() {
        kubectl exec -n "$NS_SPICEDB" "$POD" -- zed \
            --endpoint spicedb.spicedb.svc.cluster.local:50051 \
            --token "$PSK" --no-verify-ca "$@"
    }

    # zed v1 doesn't support filter-by-relation on `relationship read`.
    # Read all relationships of each resource, then delete only the
    # UUID-shaped subjects (tested 2026-05-04: format is space-separated
    # `<resource> <relation> <subject>` per line; warning lines are JSON
    # and start with `{"level"`). The Phase 4 username-keyed seed
    # (user:jason / user:alice / user:bob) is preserved by the regex.
    DELETED=0
    for RES in "tenant:helloworld" "app:helloworld-app" "document:welcome"; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            SUBJ=$(printf '%s' "$line" | awk '{print $3}')
            REL=$(printf '%s' "$line" | awk '{print $2}')
            case "$SUBJ" in
                user:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*)
                    zed_exec relationship delete "$RES" "$REL" "$SUBJ" >/dev/null 2>&1 && DELETED=$((DELETED+1)) || true
                    ;;
            esac
        done < <(zed_exec relationship read "$RES" 2>/dev/null | grep -v '"level"')
    done
    if [ "$DELETED" -gt 0 ]; then
        record "SpiceDB UUID-keyed relationships ($DELETED tuples)"
    fi

    kubectl delete pod -n "$NS_SPICEDB" "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# ─── Section 5 — OpenBao: policies, JWT roles, DB roles, KV ────────────
green "==> [5/8] openbao: all helloworld-* policy/role/db-role + KV sweep"

# Per Phase 9.12 prompt § OpenBao: delete the helloworld-bff JWT auth role,
# any helloworld-prefixed Postgres dynamic-credential role, and the
# secret/data/apps/helloworld-* KV paths. Phase 10 will mint its own
# proposal-forge-bff / project-tracker-bff / pm-bff equivalents from
# scratch. The .hcl source files in infrastructure/openbao/policies/ stay
# as reference patterns.

# 5a. Revoke + delete dynamic Postgres roles.
for ROLE in helloworld-backend-readwrite helloworld-app-readwrite helloworld-app-readonly; do
    if bao_pod bao read "database/roles/$ROLE" >/dev/null 2>&1; then
        bao_pod bao lease revoke -prefix "database/creds/$ROLE" >/dev/null 2>&1 || true
        bao_pod bao delete "database/roles/$ROLE" >/dev/null 2>&1 || true
        record "OpenBao database/roles/$ROLE (+ leases revoked)"
    fi
done

# 5b. Trim allowed_roles on database/config/secforge-app so the deleted
# roles are no longer referenced.
PG_USER=$(kubectl get secret -n "$NS_APP" secforge-app-db-app -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "app")
NEW_ALLOWED=$(bao_pod bao read -format=json database/config/secforge-app 2>/dev/null \
    | jq -r '.data.allowed_roles | map(select(test("^helloworld") | not)) | join(",")' 2>/dev/null || echo "")
if bao_pod bao read database/config/secforge-app >/dev/null 2>&1; then
    if [ -z "$NEW_ALLOWED" ]; then
        # No non-helloworld roles left → drop the whole connection config.
        bao_pod bao delete database/config/secforge-app >/dev/null 2>&1 || true
        record "OpenBao database/config/secforge-app (no non-helloworld roles remain)"
    else
        bao_pod bao write database/config/secforge-app \
            plugin_name=postgresql-database-plugin \
            allowed_roles="$NEW_ALLOWED" \
            connection_url="postgresql://{{username}}:{{password}}@secforge-app-db-rw.app.svc.cluster.local:5432/secforge_app?sslmode=require" \
            username="$PG_USER" >/dev/null 2>&1 || true
        record "OpenBao database/config/secforge-app allowed_roles trimmed (now: $NEW_ALLOWED)"
    fi
fi

# 5c. JWT auth roles for both BFF + backend.
for ROLE in helloworld-bff helloworld-backend; do
    if bao_pod bao read "auth/jwt/role/$ROLE" >/dev/null 2>&1; then
        bao_pod bao delete "auth/jwt/role/$ROLE" >/dev/null 2>&1 || true
        record "OpenBao auth/jwt/role/$ROLE"
    fi
done

# 5d. Policies. Removing these revokes any tokens still bound to them.
for POLICY in helloworld-bff helloworld-backend; do
    if bao_pod bao policy read "$POLICY" >/dev/null 2>&1; then
        bao_pod bao policy delete "$POLICY" >/dev/null 2>&1 || true
        record "OpenBao policy $POLICY"
    fi
done

# 5e. KV sweep — secret/data/apps/helloworld* recursive. The `apps/` mount
# has subdirs `helloworld/` and `helloworld-bff/` each containing leaf
# secrets; `bao kv metadata delete` requires the full leaf path. Walk
# subdir → delete each leaf.
for SUBDIR in $(bao_pod bao kv list -format=json -mount=secret apps 2>/dev/null \
    | jq -r '.[]? | select(test("^helloworld"))' 2>/dev/null || true); do
    # Strip trailing slash if present (kv list returns "subdir/").
    SUBDIR_TRIMMED="${SUBDIR%/}"
    LEAVES=$(bao_pod bao kv list -format=json -mount=secret "apps/$SUBDIR_TRIMMED" 2>/dev/null \
        | jq -r '.[]?' 2>/dev/null || true)
    for LEAF in $LEAVES; do
        bao_pod bao kv metadata delete -mount=secret "apps/$SUBDIR_TRIMMED/$LEAF" >/dev/null 2>&1 || true
        record "OpenBao secret/apps/$SUBDIR_TRIMMED/$LEAF"
    done
done

# 5f. Keycloak client private_key_jwt PEM that the BFF used at startup.
if bao_pod bao kv get -mount=secret keycloak/clients/helloworld-bff >/dev/null 2>&1; then
    bao_pod bao kv metadata delete -mount=secret keycloak/clients/helloworld-bff >/dev/null 2>&1 || true
    record "OpenBao secret/keycloak/clients/helloworld-bff"
fi

# ─── Section 6 — Postgres helloworld schema ─────────────────────────────
green "==> [6/8] postgres: drop helloworld schema + helloworld_app_owner role"

if kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -tAc "SELECT 1 FROM pg_namespace WHERE nspname='helloworld'" 2>/dev/null | grep -q 1; then
    kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -c "DROP SCHEMA helloworld CASCADE;" 2>&1 | tail -1
    record "Postgres schema secforge_app.helloworld (CASCADE)"
fi

if kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -tAc "SELECT 1 FROM pg_roles WHERE rolname='helloworld_app_owner'" 2>/dev/null | grep -q 1; then
    # Reassign anything still owned (defensive — schema drop should have
    # reassigned via CASCADE), then drop. Each statement runs independently
    # because REVOKE may legitimately fail (Postgres errors when no grant
    # exists for the requested grantee/role pair) and we don't want that
    # to abort `set -e`.
    kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -c "REASSIGN OWNED BY helloworld_app_owner TO postgres;" 2>&1 | tail -1 || true
    kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -c "DROP OWNED BY helloworld_app_owner;" 2>&1 | tail -1 || true
    kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -c "REVOKE helloworld_app_owner FROM app;" 2>&1 | tail -1 || true
    kubectl exec -n "$NS_APP" "$PG_POD" -c postgres -- psql -U postgres -d "$PG_DB" -c "DROP ROLE IF EXISTS helloworld_app_owner;" 2>&1 | tail -1
    record "Postgres role helloworld_app_owner"
fi

# ─── Section 7 — Container images ───────────────────────────────────────
green "==> [7/8] container images: helloworld-backend + helloworld-bff (docker + containerd)"

# Per Phase 9.12 prompt: drop helloworld-frontend + helloworld-backend
# images; the BFF *codebase* is preserved as the reference for Phase 10
# but the *image* gets rebuilt by Phase 10's deploy under different tags
# (proposal-forge-bff / project-tracker-bff / pm-bff). So the helloworld-bff
# image goes too — its bytes will be regenerated when Phase 10 forks.

# docker daemon side
DOCKER_IMGS=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '^(local/)?(helloworld-backend|helloworld-bff|helloworld-frontend)(:|$)' || true)
for IMG in $DOCKER_IMGS; do
    docker rmi "$IMG" >/dev/null 2>&1 || true
    record "docker image $IMG"
done

# containerd k8s.io namespace
CTR_IMGS=$(docker exec desktop-control-plane ctr -n=k8s.io image ls --quiet 2>/dev/null \
    | grep -E "helloworld-(backend|bff|frontend)" || true)
for IMG in $CTR_IMGS; do
    docker exec desktop-control-plane ctr -n=k8s.io image rm "$IMG" >/dev/null 2>&1 || true
    record "containerd image $IMG"
done

# ─── Section 8 — Final summary ─────────────────────────────────────────
green ""
green "================================================================"
green "Phase 9.12 teardown complete."
green "================================================================"
if [ "${#REMOVED_TALLY[@]}" -eq 0 ]; then
    yellow "Nothing to remove (already torn down)."
else
    green "Removed ${#REMOVED_TALLY[@]} resource(s):"
    for r in "${REMOVED_TALLY[@]}"; do
        printf '  - %s\n' "$r"
    done
fi
green ""
green "Run infrastructure/helloworld/verify-clean.sh next (Phase 9.13)."
