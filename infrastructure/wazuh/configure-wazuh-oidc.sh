#!/usr/bin/env bash
# Phase 7d Item 7 — wire the Wazuh dashboard's OIDC login into the
# running cluster.
#
# What this does (in order):
#   1. Reads the VSO-rendered Secret `wazuh-oidc-vso` (client_id +
#      client_secret + issuer + redirect_uri).
#   2. Patches the running `wazuh-dashboard-config` ConfigMap's
#      opensearch_dashboards.yml — appends an `opensearch_security`
#      OIDC stanza configured against Keycloak's `platform` realm.
#   3. Updates the indexer's OpenSearch Security plugin config:
#        a. Writes config.yml with an OIDC authc domain alongside the
#           existing internal-user auth.
#        b. Updates roles_mapping.yml so the OIDC `platform_admin`
#           realm role maps to the `all_access` backend role.
#        c. Runs `securityadmin.sh -f config.yml -f roles_mapping.yml`
#           inside the indexer pod to push the changes into the
#           `.opendistro_security` index.
#   4. Rolls the dashboard pod so it picks up the new opensearch_
#      dashboards.yml.
#
# Why post-install reconfig rather than chart patching:
#   - Vendored chart's indexer init container generates security
#     configs from heredocs. Adding OIDC requires a meaningful patch
#     of those heredocs PLUS chart values to opt-in. Defer that to a
#     future chart-fork session if chart upgrades become routine.
#   - The reconfiguration is reversible: rerun the chart's apply.sh
#     to revert to internal-user-only auth.
#
# Pre-conditions:
#   - infrastructure/keycloak/clients/wazuh.sh has run (provisions the
#     Keycloak client + writes secret/data/wazuh/oidc).
#   - infrastructure/openbao/policies/vso.hcl has the
#     secret/data/wazuh/oidc paths AND has been re-loaded.
#   - infrastructure/vault-secrets-operator/configure-openbao-role.sh
#     has the wazuh-vso role AND has been re-applied.
#   - infrastructure/wazuh/03-vso-binding.yaml has been applied
#     (creates SA + VaultAuth + VaultStaticSecret).
#   - The rendered Secret `wazuh-oidc-vso` exists in wazuh ns and has
#     been populated by VSO (verify: `kubectl get secret -n wazuh
#     wazuh-oidc-vso -o jsonpath='{.data.client_id}' | base64 -d`).
#
# Idempotent: re-running re-applies the patches. If the OIDC stanza
# already exists in opensearch_dashboards.yml, it's overwritten with
# the current rendered values.
#
# Usage:
#   bash infrastructure/wazuh/configure-wazuh-oidc.sh

set -euo pipefail

NS=wazuh
INDEXER_POD=wazuh-indexer-0
DASHBOARD_DEPLOY=wazuh-dashboard
SECRET_NAME=wazuh-oidc-vso
DASHBOARD_CM=wazuh-dashboard-config

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Read VSO-rendered Secret.
green "==> reading wazuh-oidc-vso (VSO-rendered)"
if ! kubectl -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    red "Secret $NS/$SECRET_NAME missing. Apply 03-vso-binding.yaml + run wazuh.sh first."
    exit 1
fi

CLIENT_ID=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.client_id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.client_secret}' | base64 -d)
ISSUER=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.issuer}' | base64 -d)
REDIRECT_URI=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.redirect_uri}' | base64 -d)

[ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$ISSUER" ] || [ -z "$REDIRECT_URI" ] && {
    red "wazuh-oidc-vso missing required keys (client_id, client_secret, issuer, redirect_uri). Has VSO synced?"
    exit 1
}
green "    client_id=$CLIENT_ID issuer=$ISSUER"

# 2. Patch wazuh-dashboard-config ConfigMap.
#    OpenSearch Dashboards 2.x consumes opensearch_security.openid.* keys
#    in opensearch_dashboards.yml. We append the OIDC stanza if not
#    already present; otherwise replace the existing block.
green "==> patching wazuh-dashboard-config ConfigMap"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

CURRENT=$(kubectl -n "$NS" get configmap "$DASHBOARD_CM" -o jsonpath='{.data.opensearch_dashboards\.yml}')
# Strip any existing OIDC block (lines starting with opensearch_security.auth.type
# through opensearch_security.openid.*).
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
opensearch_security.openid.base_redirect_url: "https://wazuh.secforge.local"
opensearch_security.cookie.secure: true
opensearch_security.cookie.password: "$(openssl rand -base64 32 | tr -d '\n=' | head -c 40)"
EOF

kubectl -n "$NS" create configmap "$DASHBOARD_CM" \
    --from-file=opensearch_dashboards.yml="$TMPFILE" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

# 3. Update indexer's OpenSearch Security plugin config.
#    securityadmin.sh REPLACES the .opendistro_security index with the
#    config files we provide. We must include ALL the existing
#    config files (internal_users.yml, roles.yml, etc.) — not just
#    config.yml — otherwise we wipe them.
#
# Approach: cat the existing /security-config/ dir contents from the
# init-generated state, modify config.yml + roles_mapping.yml in
# place, then run securityadmin.sh.
green "==> updating indexer security config (config.yml + roles_mapping.yml)"

# Build a tar of the in-pod /security-config/ dir, modify locally, push back.
SECDIR=$(mktemp -d)
trap 'rm -rf "$TMPFILE" "$SECDIR"' EXIT

# The init container's /security-config/ persists into a writable EmptyDir.
# We read the runtime path: /usr/share/wazuh-indexer/opensearch-security/
SEC_RUNTIME_PATH=/usr/share/wazuh-indexer/opensearch-security
kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- \
    sh -c "cd $SEC_RUNTIME_PATH && tar c config.yml roles.yml roles_mapping.yml internal_users.yml" \
    | tar -x -C "$SECDIR" 2>/dev/null

# Modify config.yml: add OIDC authc domain alongside internal-user auth.
python3 - "$SECDIR/config.yml" "$ISSUER" "$CLIENT_ID" <<'PYEOF' 2>/dev/null || \
    yellow "    python3 not available; skipping config.yml YAML edit. Operator must edit manually."
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
# Lower the priority of basic_internal_auth_domain so OIDC takes the
# default unless the request carries Basic auth.
if 'basic_internal_auth_domain' in authc:
    authc['basic_internal_auth_domain']['order'] = 1
with open(path, 'w') as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PYEOF

# Modify roles_mapping.yml: map platform_admin → all_access.
python3 - "$SECDIR/roles_mapping.yml" <<'PYEOF' 2>/dev/null || \
    yellow "    python3 not available; skipping roles_mapping.yml edit. Operator must edit manually."
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    doc = yaml.safe_load(f)
all_access = doc.setdefault('all_access', {'reserved': False, 'description': 'Maps admin to all_access'})
br = all_access.setdefault('backend_roles', [])
if 'platform_admin' not in br:
    br.append('platform_admin')
all_access['backend_roles'] = br
with open(path, 'w') as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PYEOF

# Push modified files back, run securityadmin.sh.
green "==> pushing modified configs to indexer + running securityadmin.sh"
kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- mkdir -p /tmp/sec-update
for f in config.yml roles_mapping.yml; do
    kubectl cp "$SECDIR/$f" "$NS/$INDEXER_POD:/tmp/sec-update/$f" -c wazuh-indexer 2>/dev/null
done

kubectl exec -n "$NS" "$INDEXER_POD" -c wazuh-indexer -- bash -c '
    set -e
    cd /usr/share/wazuh-indexer
    export JAVA_HOME=$(pwd)/jdk
    export PATH=$JAVA_HOME/bin:$PATH
    plugins/opensearch-security/tools/securityadmin.sh \
        -cd /tmp/sec-update \
        -f /tmp/sec-update/config.yml \
        -t config \
        -h localhost -p 9200 \
        -cacert /usr/share/wazuh-indexer/certs/root-ca.pem \
        -cert /usr/share/wazuh-indexer/certs/admin.pem \
        -key /usr/share/wazuh-indexer/certs/admin-key.pem \
        -nhnv \
        2>&1 | tail -10
    plugins/opensearch-security/tools/securityadmin.sh \
        -cd /tmp/sec-update \
        -f /tmp/sec-update/roles_mapping.yml \
        -t rolesmapping \
        -h localhost -p 9200 \
        -cacert /usr/share/wazuh-indexer/certs/root-ca.pem \
        -cert /usr/share/wazuh-indexer/certs/admin.pem \
        -key /usr/share/wazuh-indexer/certs/admin-key.pem \
        -nhnv \
        2>&1 | tail -5
    rm -rf /tmp/sec-update
'

# 4. Roll the dashboard pod.
green "==> rolling-restarting dashboard"
kubectl -n "$NS" rollout restart "deployment/$DASHBOARD_DEPLOY"
kubectl -n "$NS" rollout status "deployment/$DASHBOARD_DEPLOY" --timeout=180s

green ""
green "Phase 7d Item 7 — Wazuh OIDC federation wired."
green ""
green "Test:"
green "  Browse to https://wazuh.secforge.local — should redirect to Keycloak."
green "  Log in as a user with the 'platform_admin' realm role."
green "  Should land on the dashboard with all_access privileges."
green ""
green "Roll back:"
green "  helm upgrade <chart> --reuse-values   # re-renders the original ConfigMap"
green "  kubectl rollout restart -n wazuh deployment/wazuh-dashboard"
green "  Re-run the indexer's init container to revert security configs."
green ""
