#!/usr/bin/env bash
# 07j — Wire Wazuh dashboard's OIDC login into the running cluster.
#
# Single change from the retired local-edition configurator: maps
# `users: [jason.upole]` (subject_key=preferred_username)
# instead of `backend_roles: [platform_admin]` — same single-user workaround
# the rest of the platform (OpenBao, Grafana) uses until realm_access.roles
# claim plumbing is fixed.
#
# What this does:
#   1. Re-load vso.hcl + create K8s auth role wazuh-vso (idempotent).
#   2. Wait for VSO to render `wazuh-oidc-vso` Secret in wazuh ns.
#   3. Patch `wazuh-dashboard-config` ConfigMap to enable opensearch_security
#      OIDC against Keycloak's `platform` realm.
#   4. Update indexer's OpenSearch Security plugin config:
#        - config.yml: add openid_auth_domain alongside basic auth.
#        - roles_mapping.yml: map jason.upole → all_access.
#        - Run securityadmin.sh inside the indexer pod.
#   5. Roll the dashboard pod.
#
# Pre-conditions:
#   - 07i has run (Keycloak client + OpenBao secret/wazuh/oidc).
#   - Wazuh chart is deployed (07-wazuh.sh complete).
#   - 03-vso-binding.yaml applied (SA + VaultAuth + VaultStaticSecret).
#   - openbao-root-token-tmp Secret in openbao ns.
#
# Idempotent.
#
# OPERATIONAL GOTCHAS (learned during initial deploy 2026-05-08):
#
#  1. Re-run after any chart re-render. The chart re-renders the dashboard
#     ConfigMap `wazuh-dashboard-config` from defaults during helm upgrade,
#     wiping the OIDC `opensearch_security` stanza this script adds. Symptom:
#     dashboard reverts to local username/password login. Fix: re-run 07j.
#
#  2. Indexer must have headroom for `securityadmin.sh`. The tool starts a
#     second JVM in the indexer container alongside the running indexer JVM.
#     With the chart's default 2Gi limit, the indexer at steady state
#     (~1.85Gi) leaves no room and the container OOMKills mid-config-push.
#     `platform/values/wazuh.yaml` bumps `indexer.resources.limits.memory`
#     to 3Gi specifically so this script can run cleanly. We also pin
#     OPENSEARCH_JAVA_OPTS=-Xms128m -Xmx128m on the tool JVM. If you see
#     `command terminated with exit code 137` mid-script, the indexer
#     OOMKilled — bump memory and re-run.
#
#  3. After indexer restart, filebeat (the manager-side shipper) takes
#     ~1 minute to reconnect to the indexer. During that window the
#     dashboard shows "no matching indices for wazuh-alerts-*" even though
#     the manager keeps writing alerts to /var/ossec/logs/alerts/alerts.json
#     locally. The fix is patience — filebeat retries automatically.
#     DO NOT `kill -HUP filebeat` to speed it up; the manager pod's s6
#     supervisor treats any child exit as fatal and tears down the entire
#     container. If you need to force a faster reconnect, delete the
#     manager pod: `kubectl delete pod wazuh-manager-0`.
#
#  4. Production paths differ from local edition:
#       /usr/share/wazuh-indexer/config/opensearch-security/  (NOT .../opensearch-security/)
#       /usr/share/wazuh-indexer/config/certs/                (NOT .../certs/)
#     Indexer image lacks `tar`, so `kubectl cp` doesn't work — use
#     `kubectl exec ... -- cat` to stream files in/out.
#
#  5. PKCE NOT enforced on the wazuh-dashboard Keycloak client (07i drops
#     `pkce.code.challenge.method=S256`). The OpenSearch Dashboards OIDC
#     plugin doesn't send `code_challenge_method` and Keycloak's enforcement
#     causes ERR_TOO_MANY_REDIRECTS in the browser. Other clients keep PKCE.
#
#  6. `run_as: false` is patched into the chart's
#     `templates/dashboard/deployment.yaml` (line 140). With `run_as: true`
#     (chart default) the dashboard tries to call the Wazuh API as the
#     OIDC user (jason.upole), which doesn't exist as a Wazuh API user
#     → AGENTS SUMMARY widget reports "no agents". With `run_as: false`
#     it always uses the wazuh-wui API service account.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

NS=wazuh
NS_BAO=openbao
POD_BAO=openbao-0
INDEXER_POD=wazuh-indexer-0
DASHBOARD_DEPLOY=wazuh-dashboard
SECRET_NAME=wazuh-oidc-vso
DASHBOARD_CM=wazuh-dashboard-config
ADMIN_USER=jason.upole

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found."; exit 1
fi
if ! kubectl -n "$NS" get sa wazuh-vso >/dev/null 2>&1; then
  red "ERROR: wazuh-vso SA missing. Apply manifests/wazuh/03-vso-binding.yaml first."; exit 1
fi

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1a. Re-load vso policy (already has wazuh/oidc path)
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 1b. K8s auth role
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: wazuh-vso"
bao bao write auth/kubernetes/role/wazuh-vso \
  bound_service_account_names="wazuh-vso" \
  bound_service_account_namespaces="wazuh" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

unset ROOT_TOKEN

# 2. Wait for VSO render
green "==> waiting for VSO to render wazuh-oidc-vso (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render $SECRET_NAME within 60s"; exit 1
  fi
  sleep 5
done

CLIENT_ID=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.client_id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.client_secret}' | base64 -d)
ISSUER=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.issuer}' | base64 -d)
REDIRECT_URI=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.redirect_uri}' | base64 -d)

[ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$ISSUER" ] || [ -z "$REDIRECT_URI" ] && {
  red "wazuh-oidc-vso missing required keys"; exit 1
}
green "    client_id=$CLIENT_ID issuer=$ISSUER"

# 3. Patch wazuh-dashboard-config ConfigMap.
green "==> patching wazuh-dashboard-config ConfigMap with OIDC stanza"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

CURRENT=$(kubectl -n "$NS" get configmap "$DASHBOARD_CM" -o jsonpath='{.data.opensearch_dashboards\.yml}')
# Strip any prior OIDC block; awk only supports gawk's full set on Linux.
STRIPPED=$(printf '%s\n' "$CURRENT" | awk '
    /^opensearch_security\.auth\.type:/      { skip=1 }
    /^opensearch_security\.openid\./         { skip=1 }
    /^opensearch_security\.cookie\./         { skip=1 }
    /^[^ ]/ && !/^opensearch_security\.auth\.type:/ \
              && !/^opensearch_security\.openid\./ \
              && !/^opensearch_security\.cookie\./ { skip=0 }
    !skip
')

cat > "$TMPFILE" <<EOF
$STRIPPED
opensearch_security.auth.type: "openid"
opensearch_security.openid.connect_url: "${ISSUER}/.well-known/openid-configuration"
opensearch_security.openid.client_id: "${CLIENT_ID}"
opensearch_security.openid.client_secret: "${CLIENT_SECRET}"
opensearch_security.openid.scope: "openid profile email roles"
opensearch_security.openid.base_redirect_url: "https://wazuh.${DOMAIN}"
opensearch_security.cookie.secure: true
opensearch_security.cookie.password: "$(openssl rand -base64 32 | tr -d '\n=' | head -c 40)"
EOF

kubectl -n "$NS" create configmap "$DASHBOARD_CM" \
    --from-file=opensearch_dashboards.yml="$TMPFILE" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

# 4. Update indexer's OpenSearch Security plugin config.
green "==> updating indexer security config (config.yml + roles_mapping.yml)"

SECDIR=$(mktemp -d)
trap 'rm -f "$TMPFILE"; rm -rf "$SECDIR"' EXIT

# Indexer image has no tar (so kubectl cp won't work either). Read each
# file individually via kubectl exec ... -- cat.
SEC_RUNTIME_PATH=/usr/share/wazuh-indexer/config/opensearch-security
for f in config.yml roles.yml roles_mapping.yml internal_users.yml; do
    kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- \
        cat "$SEC_RUNTIME_PATH/$f" > "$SECDIR/$f"
done

# config.yml: add openid_auth_domain alongside basic_internal_auth_domain.
python3 - "$SECDIR/config.yml" "$ISSUER" "$CLIENT_ID" <<'PYEOF'
import sys, yaml
path, issuer, cid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    doc = yaml.safe_load(f)
authc = doc['config']['dynamic']['authc']
authc['openid_auth_domain'] = {
    'http_enabled': True,
    'transport_enabled': True,
    'order': 0,
    'http_authenticator': {
        'type': 'openid',
        'challenge': False,
        'config': {
            'subject_key': 'preferred_username',
            'roles_key': 'realm_access.roles',
            'openid_connect_url': f'{issuer}/.well-known/openid-configuration',
        },
    },
    'authentication_backend': {'type': 'noop'},
}
if 'basic_internal_auth_domain' in authc:
    authc['basic_internal_auth_domain']['order'] = 1
with open(path, 'w') as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PYEOF

# roles_mapping.yml: map user jason.upole → all_access.
python3 - "$SECDIR/roles_mapping.yml" "$ADMIN_USER" <<'PYEOF'
import sys, yaml
path, admin_user = sys.argv[1], sys.argv[2]
with open(path) as f:
    doc = yaml.safe_load(f)
all_access = doc.setdefault('all_access', {'reserved': False, 'description': 'Maps admin to all_access'})
users = all_access.setdefault('users', [])
if admin_user not in users:
    users.append(admin_user)
all_access['users'] = users
with open(path, 'w') as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PYEOF

green "==> pushing modified configs to indexer + running securityadmin.sh"
kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- mkdir -p /tmp/sec-update
# kubectl cp needs tar; the indexer image doesn't have it. Stream via
# kubectl exec ... -- sh -c 'cat > ...' instead.
for f in config.yml roles_mapping.yml; do
    kubectl exec -i -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- \
        sh -c "cat > /tmp/sec-update/$f" < "$SECDIR/$f"
done

kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- bash -c '
    set -e
    cd /usr/share/wazuh-indexer
    export JAVA_HOME=$(pwd)/jdk
    export PATH=$JAVA_HOME/bin:$PATH
    # securityadmin.sh starts another JVM in the same container as the
    # running indexer (which already uses 1.5Gi of the 2Gi limit). Pin
    # the tool to a tiny heap to stay under the limit and avoid OOMKill.
    export OPENSEARCH_JAVA_OPTS="-Xms128m -Xmx128m"
    plugins/opensearch-security/tools/securityadmin.sh \
        -cd /tmp/sec-update \
        -f /tmp/sec-update/config.yml \
        -t config \
        -h localhost -p 9200 \
        -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
        -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
        -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
        -nhnv \
        2>&1 | tail -10
    plugins/opensearch-security/tools/securityadmin.sh \
        -cd /tmp/sec-update \
        -f /tmp/sec-update/roles_mapping.yml \
        -t rolesmapping \
        -h localhost -p 9200 \
        -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
        -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
        -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
        -nhnv \
        2>&1 | tail -5
    rm -rf /tmp/sec-update
'

# 5. Roll the dashboard.
green "==> rolling-restarting dashboard"
kubectl -n "$NS" rollout restart "deployment/$DASHBOARD_DEPLOY"
kubectl -n "$NS" rollout status "deployment/$DASHBOARD_DEPLOY" --timeout=180s

cat <<EOF

✓ Wazuh OIDC federation wired.

Test:
  Browse to https://wazuh.${DOMAIN}
  → redirects to Keycloak
  → log in as $ADMIN_USER (passkey + TOTP)
  → lands on the dashboard with all_access privileges.

Roll back:
  helm upgrade <chart> --reuse-values   # re-renders the original ConfigMap
  kubectl rollout restart -n wazuh deployment/wazuh-dashboard
  Re-run the indexer's init container to revert security configs.
EOF
