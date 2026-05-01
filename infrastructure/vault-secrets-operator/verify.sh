#!/usr/bin/env bash
# Phase 6.10b Step 2 — verify VSO is healthy and can auth to OpenBao.
#
# Run AFTER apply.sh and configure-openbao-role.sh. This script does not
# render any Secret yet (that's Step 3); it only confirms the platform
# wiring is correct.

set -euo pipefail

NS=vault-secrets-operator

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Pod healthy.
green "==> Checking VSO controller pod"
if ! kubectl -n "$NS" rollout status deployment/vault-secrets-operator-controller-manager --timeout=30s; then
    red "VSO Deployment is not Ready."
    exit 1
fi

# 2. VaultConnection + VaultAuth resources exist and report status.
green "==> Checking VaultConnection 'openbao'"
kubectl -n "$NS" get vaultconnection openbao -o wide || {
    red "VaultConnection 'openbao' not found."; exit 1; }

green "==> Checking VaultAuth 'default'"
kubectl -n "$NS" get vaultauth default -o wide || {
    red "VaultAuth 'default' not found."; exit 1; }

# 3. Probe authentication by creating a VaultStaticSecret pointed at the
#    SpiceDB preshared key path, watching it materialize, then deleting it.
#
#    Probe runs in the OPERATOR'S OWN namespace, not in spicedb. Reason:
#    VSO obtains its K8s auth token via TokenRequest against the SA
#    referenced by VaultAuth, and TokenRequest is namespace-scoped — the
#    SA must live in the SAME namespace as the VaultStaticSecret. For
#    cross-ns rendering (Step 3), each consumer namespace needs its own
#    SA + VaultAuth + OpenBao role binding. For Step 2 verification, an
#    in-namespace probe exercises the full auth + read + render path
#    without dragging Step 3 setup forward.
PROBE_NS=vault-secrets-operator
PROBE_NAME=vso-auth-probe
yellow "==> Auth probe: creating temporary VaultStaticSecret '$PROBE_NAME' in $PROBE_NS"
yellow "    (this exercises the full VSO auth + read + render path)"

cat <<EOF | kubectl apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: $PROBE_NAME
  namespace: $PROBE_NS
  labels:
    secforge.platform/component: vault-secrets-operator
    secforge.platform/role: auth-probe
spec:
  # Cross-K8s-namespace reference: <ns>/<name>. Schema confirmed via
  # 'kubectl explain vaultstaticsecret.spec.vaultAuthRef'.
  vaultAuthRef: vault-secrets-operator/default
  mount: secret
  type: kv-v2
  path: spicedb/preshared-key
  refreshAfter: 600s
  destination:
    name: $PROBE_NAME
    create: true
EOF

green "==> Waiting up to 30s for $PROBE_NS/$PROBE_NAME Secret to be rendered"
for i in $(seq 1 30); do
    if kubectl -n "$PROBE_NS" get secret "$PROBE_NAME" >/dev/null 2>&1; then
        green "    rendered after ${i}s"
        break
    fi
    sleep 1
done

if ! kubectl -n "$PROBE_NS" get secret "$PROBE_NAME" >/dev/null 2>&1; then
    red "Probe failed: Secret was not rendered within 30s."
    red "Check VSO logs:"
    red "  kubectl -n $NS logs deploy/vault-secrets-operator-controller-manager --tail=80"
    yellow "Cleaning up probe resources before exit..."
    kubectl -n "$PROBE_NS" delete vaultstaticsecret "$PROBE_NAME" --ignore-not-found
    exit 1
fi

green "==> Probe succeeded. Cleaning up."
kubectl -n "$PROBE_NS" delete vaultstaticsecret "$PROBE_NAME"
kubectl -n "$PROBE_NS" delete secret "$PROBE_NAME" --ignore-not-found

green ""
green "VSO is healthy and authenticated against OpenBao."
green "Ready for Step 3 (VaultStaticSecret for spicedb-config-vso)."
green ""
