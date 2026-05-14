#!/usr/bin/env bash
# 09h — CloudNativePG Barman Cloud Plugin v0.12.0 installation + wiring.
#
# The Barman Cloud Plugin replaces the deprecated inline barmanObjectStore
# config in CNPG cluster specs (deprecated in CNPG 1.26, removed in 1.30).
#
# What this script does (idempotent):
#   1. Install the barman-cloud plugin manifest in cnpg-system namespace.
#   2. Patch the Deployment to add resource limits (upstream manifest has none).
#   3. Wait for cert-manager to issue the plugin's mTLS TLS Secrets.
#   4. Copy TLS Secrets to postgres-operator (operator reads them from its own ns).
#   5. Apply the ExternalName Service in postgres-operator with cnpg.io/pluginName
#      label so the operator discovers the plugin.
#   6. Apply NetworkPolicy allowing CNPG operator egress to cnpg-system:9090.
#   7. Apply ObjectStore CRs in keycloak + spicedb namespaces.
#   8. Update cluster specs (02-cnpg-cluster.yaml) to replace barmanObjectStore
#      with the plugin reference.
#   9. Update ScheduledBackup CRs to use method: plugin.
#
# Namespace gap (documented in plan gap #25):
#   The upstream manifest hardcodes cnpg-system. The CNPG operator only discovers
#   plugin Services in its own namespace (postgres-operator). The ExternalName
#   Service in step 5 bridges the two namespaces.
#
# NetworkPolicy gap (documented in plan gap #25):
#   default-deny-egress in postgres-operator blocks port 9090. The NetworkPolicy
#   in step 6 (07-egress-barman-cloud-plugin.yaml) opens it.
#
# Pre-conditions:
#   - 01-cloudnativepg.sh complete (CNPG operator running in postgres-operator).
#   - 09b-cnpg-backups.sh complete (cnpg-minio-credentials in keycloak + spicedb,
#     VSO bindings exist — this script updates clusters but doesn't re-provision
#     MinIO credentials).
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
M="$PLATFORM_DIR/manifests"

NS_CNPG=cnpg-system
NS_OP=postgres-operator

BARMAN_VERSION=v0.12.0
BARMAN_MANIFEST_URL="https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_VERSION}/manifest.yaml"

CLUSTERS=("keycloak:secforge-keycloak-db" "spicedb:secforge-spicedb-db")

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. Install barman-cloud plugin ────────────────────────────────────────────
green ">>> Installing barman-cloud plugin ${BARMAN_VERSION}"
kubectl apply -f "$BARMAN_MANIFEST_URL"

# ─── 2. Patch resource limits (upstream manifest has resources: {}) ────────────
green ">>> Patching barman-cloud Deployment resource limits"
kubectl patch deploy -n "$NS_CNPG" barman-cloud --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {
    "requests": {"cpu": "50m", "memory": "64Mi"},
    "limits":   {"cpu": "200m", "memory": "256Mi"}
  }}
]' 2>/dev/null || true

# ─── 3. Wait for cert-manager to issue the plugin's TLS Secrets ────────────────
green ">>> Waiting for barman-cloud TLS Secrets (up to 120s)"
for secret in barman-cloud-client-tls barman-cloud-server-tls; do
  for i in $(seq 1 24); do
    if kubectl -n "$NS_CNPG" get secret "$secret" >/dev/null 2>&1; then
      green "    $secret ready after $((i*5))s"; break
    fi
    if [ "$i" -eq 24 ]; then
      red "ERROR: $secret not found in $NS_CNPG after 120s"; exit 1
    fi
    sleep 5
  done
done

# ─── 4. Copy TLS Secrets to postgres-operator ──────────────────────────────────
green ">>> Copying TLS Secrets to $NS_OP"
for secret in barman-cloud-client-tls barman-cloud-server-tls; do
  kubectl get secret -n "$NS_CNPG" "$secret" -o json \
    | jq "del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences)" \
    | jq ".metadata.namespace = \"$NS_OP\"" \
    | kubectl apply -f - 2>&1 | tail -1
done

# ─── 5. ExternalName Service in postgres-operator ──────────────────────────────
green ">>> Applying barman-cloud ExternalName Service in $NS_OP"
kubectl apply -f "$M/postgres-operator/08-barman-cloud-plugin-svc.yaml"

# ─── 6. NetworkPolicy: allow CNPG operator egress to cnpg-system:9090 ──────────
green ">>> Applying NetworkPolicy allow-egress-barman-cloud-plugin"
kubectl apply -f "$M/postgres-operator/07-egress-barman-cloud-plugin.yaml"

# ─── 7. ObjectStore CRs ────────────────────────────────────────────────────────
green ">>> Applying ObjectStore CRs"
kubectl apply -f "$M/keycloak/08-objectstore.yaml"
kubectl apply -f "$M/spicedb/08-objectstore.yaml"

# Wait for ObjectStore reconciliation
sleep 5

# ─── 8. Update cluster specs to use the plugin ─────────────────────────────────
green ">>> Updating CNPG cluster specs (plugin reference)"
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  green "    patching cluster in $ns"
  kubectl apply -f "$M/$ns/02-cnpg-cluster.yaml"
done

# ─── 9. Update ScheduledBackup CRs ─────────────────────────────────────────────
green ">>> Updating ScheduledBackup CRs (method: plugin)"
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  kubectl apply -f "$M/$ns/07-cnpg-scheduled-backup.yaml"
done

# ─── Wait for clusters to reconcile ────────────────────────────────────────────
green ">>> Waiting for clusters to reach healthy state (up to 5m)"
for entry in "${CLUSTERS[@]}"; do
  ns="${entry%%:*}"
  cluster="${entry##*:}"
  kubectl wait cluster -n "$ns" "$cluster" \
    --for=jsonpath='{.status.phase}'='Cluster in healthy state' \
    --timeout=300s 2>&1 | tail -1
done

cat <<EOF

✓ Barman Cloud Plugin v${BARMAN_VERSION} wired.

  Plugin:        barman-cloud Deployment in $NS_CNPG (2/2 sidecar injected into cluster pods)
  ObjectStores:  keycloak/minio-backup, spicedb/minio-backup
  Plugin svc:    barman-cloud ExternalName in $NS_OP → $NS_CNPG:9090
  NetworkPolicy: allow-egress-barman-cloud-plugin in $NS_OP

  Verify:
    kubectl get cluster -A
    kubectl get objectstore -A
    kubectl get backup -n keycloak | head -3
    kubectl get backup -n spicedb  | head -3

  Test backup:
    kubectl create -f - <<'BEOF'
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: manual-test
      namespace: keycloak
    spec:
      method: plugin
      pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
      cluster:
        name: secforge-keycloak-db
    BEOF
    kubectl wait backup -n keycloak manual-test --for=jsonpath='{.status.phase}'=completed --timeout=120s

  If clusters fail to reconcile, check:
    kubectl logs -n $NS_OP -l app.kubernetes.io/name=cloudnative-pg --tail=20
    kubectl logs -n $NS_CNPG deploy/barman-cloud --tail=20
EOF
