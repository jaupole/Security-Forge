#!/usr/bin/env bash
# Bootstrap the OpenBao auth/jwt role for the SpiceDB datastore-URI refresher
# CronJob (deployed in Phase 7d.2.c via infrastructure/spicedb/cron/).
#
# This is the canonical, idempotent bootstrap for the
# `spicedb-datastore-refresher` JWT auth role. Originally introduced as a
# one-shot remediation script for the orphan-lease bug surfaced during
# Phase 9 deployment (2026-05-04), but the only script in the tree that
# creates this role — so it is now the bootstrap.
#
# Pre-conditions:
#   - main OpenBao is unsealed and reachable
#   - `auth/jwt` is enabled (configure-auth-k8s-jwt.sh)
#   - policy `spicedb-datastore-refresher` is loaded (load-policies.sh
#     handles this from infrastructure/openbao/policies/)
#
# Why token_ttl > credential default_ttl:
#   OpenBao binds dynamic-credential leases to the token that requested
#   them. When that auth token expires, ALL its child leases are revoked
#   immediately, regardless of the credential's own default_ttl. The
#   refresher mints a credential against `database/roles/spicedb-readwrite`
#   whose default_ttl is 14h (per Phase 7d.2.c — gives 12h overlap with
#   the next CronJob firing). The auth token therefore needs token_ttl > 14h.
#   We pick 15h (1h headroom). This is the same pattern applied to the
#   helloworld-backend role in infrastructure/helloworld/provision-db-and-bao.sh.
#
# Auth: BAO_TOKEN must be an admin token (initial root, OIDC admin, or
# the kubernetes break-glass token from openbao-recovery.md).
#
# Idempotent — safe to re-run.

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Pass an admin token:\n" >&2
    printf "  BAO_TOKEN=s.XXX bash configure-auth-jwt-spicedb-refresher.sh\n" >&2
    exit 1
fi

NS=openbao
POD=openbao-0

green() { printf '\033[32m%s\033[0m\n' "$*"; }

bao() {
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

green "==> auth/jwt/role/spicedb-datastore-refresher"
green "    bound_subject = spiffe://secforge.local/ns/spicedb/sa/spicedb-datastore-refresher"
green "    token_ttl = 15h (covers 14h credential lease + 1h headroom)"
bao bao write auth/jwt/role/spicedb-datastore-refresher \
    role_type=jwt \
    bound_audiences=openbao \
    bound_subject="spiffe://secforge.local/ns/spicedb/sa/spicedb-datastore-refresher" \
    user_claim=sub \
    token_policies=spicedb-datastore-refresher \
    token_ttl=15h \
    token_max_ttl=15h 2>&1 | tail -1

green ""
green "Done. Verify the next refresher firing leaves a credential alive past 10m:"
green ""
green "    kubectl create job --from=cronjob/spicedb-datastore-refresher \\"
green "        spicedb-fix-verify-\$(date +%s) -n spicedb"
green ""
green "After 12+ minutes, kubectl exec -n spicedb spicedb-spicedb-... -c spicedb"
green "should still answer CheckPermission successfully."
