#!/usr/bin/env bash
# Phase 6.10b Step 3 — write secret/data/spicedb/config to OpenBao.
#
# This is a ONE-TIME migration. It reads the current values from the K8s
# Secret `spicedb/spicedb-config` (preshared_key + datastore_uri) and
# writes both to OpenBao at `secret/data/spicedb/config`.
#
# Why a separate path from secret/data/spicedb/preshared-key:
#   AuthZEN's VSO role reads ONLY preshared-key (defense in depth — it
#   has no business reading the Postgres password). SpiceDB's VSO role
#   reads the combined `config` path. See ADR-0015 §"Open questions"
#   and the policy at infrastructure/openbao/policies/vso.hcl.
#
# Known limitation:
#   datastore_uri is a static copy. CNPG rotation of the Postgres
#   password will desync it. The proper fix is OpenBao's database
#   secrets engine for SpiceDB (analogous to the helloworld-app setup
#   from Phase 5.7). Tracked post-6.10b.
#
# Pre-conditions:
#   - bao CLI on host (~/.local/bin; installed in Step 2)
#   - BAO_TOKEN exported from `bao login -method=oidc role=admin`
#     (UI flow until the CLI redirect URI gap is fixed — Phase 7
#     follow-up #3 in PLAN.md)
#   - K8s Secret spicedb/spicedb-config exists with both keys

set -euo pipefail

NS=openbao
POD=openbao-0

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Authenticate first:\n" >&2
    printf "  bao login -method=oidc role=admin   # via UI\n" >&2
    printf "  export BAO_TOKEN=<from-UI-or-bao-print-token>\n" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao_exec() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# Read current values from the K8s Secret (the source of truth today).
green "==> reading current spicedb/spicedb-config values"
PSK=$(kubectl get secret -n spicedb spicedb-config \
    -o jsonpath='{.data.preshared_key}' | base64 -d)
DSN=$(kubectl get secret -n spicedb spicedb-config \
    -o jsonpath='{.data.datastore_uri}' | base64 -d)

if [ -z "$PSK" ] || [ -z "$DSN" ]; then
    red "could not read preshared_key or datastore_uri from spicedb-config Secret"
    exit 1
fi

# Sanity-check that the PSK matches what's already at the OpenBao
# preshared-key path (Phase 5.10's migrate). If not, something has
# drifted and we should stop before papering over it.
green "==> sanity-check: K8s PSK matches OpenBao secret/data/spicedb/preshared-key"
EXISTING_PSK=$(bao_exec bao kv get -mount=secret -field=preshared_key spicedb/preshared-key 2>/dev/null || true)
if [ -z "$EXISTING_PSK" ]; then
    red "could not read existing OpenBao path secret/data/spicedb/preshared-key"
    red "(Phase 5.10 should have populated this — investigate before continuing)"
    exit 1
fi
if [ "$EXISTING_PSK" != "$PSK" ]; then
    red "PSK MISMATCH:"
    red "  K8s spicedb/spicedb-config.preshared_key != OpenBao secret/data/spicedb/preshared-key"
    red "Stop and investigate. Drift here means one of the two has been"
    red "rotated independently and consumers are split-brained."
    exit 1
fi

# Write the combined config path. `bao kv put` is idempotent on KV-v2;
# re-running creates a new version with the same data.
green "==> writing secret/data/spicedb/config (preshared_key + datastore_uri)"
bao_exec bao kv put -mount=secret spicedb/config \
    preshared_key="$PSK" \
    datastore_uri="$DSN" 2>&1 | tail -3

unset PSK DSN EXISTING_PSK

green ""
green "Done. Verify with:"
green "  kubectl exec -n openbao openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \\"
green "      BAO_TOKEN=\$BAO_TOKEN bao kv get -mount=secret spicedb/config"
green ""
green "Next: bash infrastructure/vault-secrets-operator/cutover.sh"
green ""
