#!/usr/bin/env bash
# 04 — SpiceDB (authorization engine)
#
# Depends on: 01-cloudnativepg, 02-spire (workload identity for SPIFFE-CSI mount)
#
# Installs:
#   1. Namespace (PSS restricted)
#   2. Operator bundle (creates spicedb-operator namespace + Deployment + CRDs)
#   3. CloudNativePG Cluster CR (Postgres for SpiceDB)
#   4. spicedb-config Secret (PSK + datastore_uri assembled from CNPG-issued app Secret)
#   5. ServiceAccount, Certificate (self-signed Issuer for in-cluster gRPC TLS)
#   6. NetworkPolicies
#   7. SpiceDBCluster CR
#
# Idempotent — PSK is preserved across re-runs (regenerating it would invalidate clients).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/spicedb"

# shellcheck disable=SC1091
set -a; source "$PLATFORM_DIR/globals.env"; set +a

# 1. Namespace
echo ">>> Creating spicedb namespace"
kubectl apply -f "$M/01-namespace.yaml"

# 2. Operator bundle
echo ">>> Applying SpiceDB Operator bundle"
kubectl apply --server-side -f "$M/operator/bundle.yaml"
echo ">>> Waiting for spicedb-operator Deployment Ready"
kubectl -n spicedb-operator rollout status deployment/spicedb-operator --timeout=300s

# 3. CloudNativePG Cluster (envsubst for ${STORAGE_CLASS})
echo ">>> Creating CloudNativePG cluster for SpiceDB"
"$LIB/apply-manifest.sh" "$M/02-cnpg-cluster.yaml"

echo ">>> Waiting for CNPG app Secret to appear (~30-60s)"
for _ in {1..60}; do
  if kubectl -n spicedb get secret secforge-spicedb-db-app >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! kubectl -n spicedb get secret secforge-spicedb-db-app >/dev/null 2>&1; then
  echo "ERROR: CNPG app Secret secforge-spicedb-db-app did not appear within 2 min" >&2
  echo "       Check: kubectl -n spicedb get cluster,pods,events" >&2
  exit 1
fi

# 4. spicedb-config Secret (idempotent — preserve PSK across re-runs)
if ! kubectl -n spicedb get secret spicedb-config >/dev/null 2>&1; then
  echo ">>> Generating PSK and assembling datastore_uri"
  PG_USER=$(kubectl -n spicedb get secret secforge-spicedb-db-app -o jsonpath='{.data.username}' | base64 -d)
  PG_PASS=$(kubectl -n spicedb get secret secforge-spicedb-db-app -o jsonpath='{.data.password}' | base64 -d)
  PG_DB=$(kubectl -n spicedb get secret secforge-spicedb-db-app -o jsonpath='{.data.dbname}' | base64 -d)
  PG_HOST="secforge-spicedb-db-rw.spicedb.svc"
  DATASTORE_URI="postgres://${PG_USER}:${PG_PASS}@${PG_HOST}:5432/${PG_DB}?sslmode=require"
  PSK="$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)"

  kubectl create secret generic spicedb-config \
    --namespace spicedb \
    --from-literal=preshared_key="$PSK" \
    --from-literal=datastore_uri="$DATASTORE_URI"
  kubectl -n spicedb label secret spicedb-config \
    app.kubernetes.io/name=spicedb \
    secforge.platform/component=spicedb \
    --overwrite

  unset PG_PASS PSK DATASTORE_URI
  cat <<'BANNER'

================================================================
  spicedb-config Secret created (PSK + datastore_uri).

  Retrieve PSK (used by zed CLI / AuthZEN facade):
    kubectl -n spicedb get secret spicedb-config \
      -o jsonpath='{.data.preshared_key}' | base64 -d

  Phase 5 will replace this with VSO-rendered creds from OpenBao.
================================================================
BANNER
else
  echo ">>> spicedb-config Secret already exists; preserving"
fi

# 5. ServiceAccount + Certificate
kubectl apply -f "$M/03-serviceaccount.yaml"
echo ">>> Applying gRPC TLS Issuer + Certificate"
kubectl apply -f "$M/04-certificate.yaml"

# 6. NetworkPolicies
echo ">>> Applying NetworkPolicies"
kubectl apply -f "$M/05-networkpolicies.yaml"
# Layer-A egress baseline — per-namespace allows (operator-backlog #51).
kubectl apply -f "$M/09-egress-otel.yaml"
kubectl apply -f "$M/10-egress-to-minio.yaml"

# 7. SpiceDBCluster CR
echo ">>> Applying SpiceDBCluster CR"
kubectl apply -f "$M/05-spicedb-cr.yaml"

# Wait for the operator-generated Deployment.
# The operator names the Deployment "<cluster-name>-spicedb" — so for our
# SpiceDBCluster named `spicedb`, the Deployment is `spicedb-spicedb`.
echo ">>> Waiting for SpiceDB Deployment to be created (operator may take ~30-60s while migration runs)"
for _ in {1..120}; do
  if kubectl -n spicedb get deployment spicedb-spicedb >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo ">>> Waiting for SpiceDB Deployment to be Ready"
kubectl -n spicedb rollout status deployment/spicedb-spicedb --timeout=300s

echo
echo "✓ SpiceDB deployed."
echo
echo "Verify:"
echo "  kubectl get pods -n spicedb"
echo "  kubectl get spicedbcluster -n spicedb"
