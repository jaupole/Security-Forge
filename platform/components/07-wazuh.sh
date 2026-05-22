#!/usr/bin/env bash
# 07 — Wazuh stack (manager + indexer + dashboard).
#
# Vendored chart: ileonelperea/wazuh-helm v1.2.10 (App 4.14.5).
# Mitigations + design notes: see platform/values/wazuh.yaml.
#
# Order:
#   1. Namespace (PSS=baseline)
#   2. NetworkPolicies (apply BEFORE workloads — avoids race)
#   3. Pre-create 4 credential Secrets (existingSecrets pattern)
#   4. helm install/upgrade against vendored chart
#   5. Wait for indexer → manager → dashboard Ready

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/wazuh"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

NS=wazuh
RELEASE=wazuh
CHART="$M/vendor-chart"

# 1. Namespace
echo ">>> Creating wazuh namespace"
kubectl apply -f "$M/01-namespace.yaml"

# 2. NetworkPolicies (BEFORE workloads to avoid race)
echo ">>> Applying NetworkPolicies"
kubectl apply -f "$M/02-networkpolicies.yaml"

# 3. Pre-create credentials Secrets (idempotent; preserves existing).
# Wazuh enforces 8-64 chars / mixed case / digit / special. We restrict
# specials to ".*+?=!" because ileonelperea's filebeat init uses sed with
# `|` and `&` as metacharacters — using either would corrupt the substitution.
gen_pw() {
  python3 - <<'PY'
import secrets, string
specials = ".*+?=!"
alphabet = string.ascii_letters + string.digits + specials
while True:
  pw = "".join(secrets.choice(alphabet) for _ in range(32))
  if (any(c.isupper() for c in pw) and any(c.islower() for c in pw)
      and any(c.isdigit() for c in pw) and any(c in specials for c in pw)):
    print(pw); break
PY
}

create_or_keep() {
  local name="$1"; shift
  if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
    echo "    secret/$name exists, keeping"
  else
    kubectl create secret generic -n "$NS" "$name" "$@" >/dev/null
    echo "    secret/$name created"
  fi
}

echo ">>> Pre-creating credentials Secrets"
create_or_keep wazuh-indexer-creds   --from-literal=username=admin     --from-literal=password="$(gen_pw)"
create_or_keep wazuh-api-creds       --from-literal=username=wazuh-wui --from-literal=password="$(gen_pw)"
create_or_keep wazuh-dashboard-creds --from-literal=password="$(gen_pw)"
create_or_keep wazuh-filebeat-creds  --from-literal=password="$(gen_pw)"
kubectl -n "$NS" label secret \
  wazuh-indexer-creds wazuh-api-creds wazuh-dashboard-creds wazuh-filebeat-creds \
  secforge.platform/component=wazuh --overwrite >/dev/null

# 4. Helm install/upgrade against the vendored chart.
# Use install-helm.sh wrapper so envsubst processes ${DOMAIN}, ${LE_ISSUER}, ${STORAGE_CLASS}.
"$LIB/install-helm.sh" \
  --release "$RELEASE" \
  --namespace "$NS" \
  --chart "$CHART" \
  --values "$PLATFORM_DIR/values/wazuh.yaml"

# 5. Watch-for-Ready (indexer → manager → dashboard).
echo ">>> Waiting for cert-bootstrap Job"
kubectl -n "$NS" wait --for=condition=Complete job/wazuh-certs-generator --timeout=300s 2>&1 | tail -1 \
  || echo "    cert-bootstrap may be Complete already; continuing"

echo ">>> Waiting for indexer (StatefulSet) Ready"
kubectl -n "$NS" rollout status statefulset/wazuh-indexer --timeout=600s

echo ">>> Waiting for manager (StatefulSet) Ready"
kubectl -n "$NS" rollout status statefulset/wazuh-manager --timeout=600s

echo ">>> Waiting for dashboard (Deployment) Ready"
kubectl -n "$NS" rollout status deployment/wazuh-dashboard --timeout=300s

cat <<EOF

✓ Wazuh stack deployed.

  Dashboard:  https://wazuh.${DOMAIN}
  User:       admin
  Password:   kubectl -n wazuh get secret wazuh-indexer-creds -o jsonpath='{.data.password}' | base64 -d
              ^ NOT wazuh-dashboard-creds — that's the internal kibanaserver
                password used by the dashboard to talk to the indexer.
                The login admin user lives on the indexer (OpenSearch), so
                its password is in wazuh-indexer-creds.

Cert may take 1-2 min to issue via Let's Encrypt; check:
  kubectl -n wazuh get certificate wazuh-dashboard-tls

Next: agent install on the host (or via DaemonSet) to feed events.
  bash ~/secforge/platform/components/07b-wazuh-agent.sh
EOF
