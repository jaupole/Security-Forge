#!/usr/bin/env bash
# Apply the spicedb-datastore-refresher CronJob (Phase 7d.2.c, ADR-0023).
#
# Pre-conditions:
#   1. cert-manager mkcert ClusterIssuer + mkcert-ca-key-pair Secret in
#      cert-manager ns (Phase 1 foundation).
#   2. policy spicedb-datastore-refresher loaded into OpenBao
#      (load-policies.sh handles this from
#      infrastructure/openbao/policies/spicedb-datastore-refresher.hcl).
#   3. JWT auth role spicedb-datastore-refresher registered in OpenBao
#      (configure-auth-jwt-spicedb-refresher.sh; the canonical bootstrap
#      that sets token_ttl=15h to outlive the 14h credential lease).
#
# What this script does:
#   1. Copies the mkcert CA bundle into the spicedb namespace as Secret
#      openbao-ca-bundle so the refresher pod can verify OpenBao's
#      mkcert-issued serving cert (replaces an earlier `curl -ksS`
#      pattern; mirrors VSO's apply.sh).
#   2. kubectl apply -f spicedb-datastore-refresher.yaml.
#
# Idempotent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=spicedb

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. CA bundle.
green "==> copying mkcert CA into $NS as openbao-ca-bundle"
CA_PEM=$(kubectl get secret -n cert-manager mkcert-ca-key-pair \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [ -z "$CA_PEM" ]; then
    red "could not read mkcert-ca-key-pair from cert-manager namespace"
    exit 1
fi
kubectl create secret generic openbao-ca-bundle \
    -n "$NS" \
    --from-literal=ca.crt="$CA_PEM" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" label secret openbao-ca-bundle \
    secforge.platform/component=spicedb-datastore-refresher \
    --overwrite >/dev/null

# 2. CronJob + ServiceAccount + ConfigMaps + NetworkPolicy.
green "==> applying spicedb-datastore-refresher.yaml"
kubectl apply -f "$HERE/spicedb-datastore-refresher.yaml"

green ""
green "Done. Verify with:"
green "  kubectl get cronjob -n $NS spicedb-datastore-refresher"
green ""
green "Trigger a one-shot manual refresh:"
green "  kubectl create job --from=cronjob/spicedb-datastore-refresher \\"
green "      spicedb-refresh-manual-\$(date +%s) -n $NS"
