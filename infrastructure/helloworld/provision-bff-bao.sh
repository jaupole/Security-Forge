#!/usr/bin/env bash
# Phase 9.6 — provision the OpenBao state the helloworld-bff needs to run.
# Operator-backlog #13 (closed 2026-05-05) replaced an env-var Valkey
# password with this OpenBao-backed flow; this script encodes the
# bootstrap permanently (NOT a one-shot migration).
#
# What this creates (idempotent):
#
#   OpenBao:
#     - secret/data/apps/helloworld-bff/valkey
#         password = <fetched from chart-managed valkey/valkey Secret>
#     - policy helloworld-bff  (loaded from policies/helloworld-bff.hcl)
#     - auth/jwt/role/helloworld-bff
#         bound_subject = spiffe://secforge.local/ns/app/sa/helloworld-bff
#         token_policies = [helloworld-bff]
#         token_ttl = 90m
#         token_max_ttl = 90m
#
# Why the policy + auth role live here (not in a generic OpenBao
# bootstrap): they're app-specific. Sister script provision-db-and-bao.sh
# handles helloworld-backend's policy + auth role; same convention.
#
# Why the Valkey password: the chart-managed Secret `valkey/valkey`
# (key `valkey-password`) is the source of truth for what the Valkey
# server actually accepts. This script copies that value into OpenBao
# so apps/lib/secrets/ can serve it to the BFF at runtime. Re-run this
# script after any Valkey password rotation.
#
# Why token_ttl=90m even though the credential is static: matches the
# helloworld-backend pattern + the Phase 9 retro rule (token_ttl ≥
# any credential default_ttl that the same role might mint downstream).
# 90m is plenty for a re-auth cycle and keeps a short blast radius if
# the SVID itself is compromised.
#
# Pre-conditions:
#   - Phase 5.7 (configure-engines.sh) ran — KV-v2 mounted at secret/
#   - Phase 5.8 (configure-auth-k8s-jwt.sh) ran — JWT auth method enabled
#   - Valkey is deployed (valkey/valkey Secret exists with `valkey-password`)
#   - BAO_TOKEN exported with admin-tier capabilities
#       (e.g. via `bao login -method=oidc role=admin`)
#
# Teardown:
#   Phase 9.12 (infrastructure/helloworld/teardown.sh) reverses the
#   OpenBao state above (drops the JWT role, the policy, the KV path).

set -euo pipefail

if [ -z "${BAO_TOKEN:-}" ]; then
    printf "BAO_TOKEN env not set. Use:\n" >&2
    printf "  export BAO_ADDR=https://bao.secforge.local; export BAO_SKIP_VERIFY=1\n" >&2
    printf "  bao login -method=oidc role=admin -format=json | jq -r .auth.client_token > ~/.bao-token\n" >&2
    printf "  BAO_TOKEN=\$(cat ~/.bao-token) bash $(basename "$0")\n" >&2
    exit 1
fi

NS_BAO=openbao
BAO_POD=openbao-0
NS_VALKEY=valkey
VALKEY_SECRET=valkey
VALKEY_FIELD=valkey-password
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bao() {
    kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# ─── Section 1 — fetch Valkey password from the chart-managed Secret ───
green "==> reading Valkey password from $NS_VALKEY/$VALKEY_SECRET:$VALKEY_FIELD"
if ! kubectl get secret -n "$NS_VALKEY" "$VALKEY_SECRET" >/dev/null 2>&1; then
    red "Secret $NS_VALKEY/$VALKEY_SECRET not found. Deploy Valkey first:"
    red "  helm install valkey bitnami/valkey -n valkey \\"
    red "      --version 5.5.1 -f infrastructure/valkey/values.yaml"
    exit 1
fi
PW=$(kubectl get secret -n "$NS_VALKEY" "$VALKEY_SECRET" -o jsonpath="{.data.$VALKEY_FIELD}" | base64 -d)
if [ -z "$PW" ]; then
    red "Secret $NS_VALKEY/$VALKEY_SECRET has empty .data.$VALKEY_FIELD"
    exit 1
fi
green "    read $(printf '%s' "$PW" | wc -c) bytes"

# ─── Section 2 — write to OpenBao KV-v2 ───────────────────────────────
green "==> OpenBao: secret/data/apps/helloworld-bff/valkey"
# Pipe the value via stdin so it never appears in command-line args.
# `bao kv put` accepts `field=-` to read the value from stdin.
printf '%s' "$PW" | bao bao kv put secret/apps/helloworld-bff/valkey password=- >/dev/null
unset PW
green "    KV write succeeded"

# Verify reads back at the canonical KV-v2 read path.
if ! bao bao kv get -format=json secret/apps/helloworld-bff/valkey \
    | grep -q '"password"'; then
    red "KV verify-read failed at secret/apps/helloworld-bff/valkey"
    exit 1
fi

# ─── Section 3 — load OpenBao policy ──────────────────────────────────
green "==> OpenBao: load policy helloworld-bff"
POLICY_FILE="$HERE/../openbao/policies/helloworld-bff.hcl"
if [ ! -f "$POLICY_FILE" ]; then
    red "policy file not found at $POLICY_FILE"
    exit 1
fi
kubectl exec -n "$NS_BAO" "$BAO_POD" -c openbao -i -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" \
    bao policy write helloworld-bff - <"$POLICY_FILE" 2>&1 | tail -1

# ─── Section 4 — JWT auth role ────────────────────────────────────────
green "==> OpenBao: auth/jwt/role/helloworld-bff"
# token_ttl=90m matches the helloworld-backend pattern (Phase 9 retro
# rule: token_ttl ≥ any credential default_ttl the same role might mint
# downstream). The helloworld-bff role today only reads static KV (no
# dynamic creds), but the rule is uniform across BFFs to avoid surprises
# if a Phase-10 BFF later mints dynamic creds against this same auth role.
bao bao write auth/jwt/role/helloworld-bff \
    role_type=jwt \
    bound_audiences=openbao \
    bound_subject="spiffe://secforge.local/ns/app/sa/helloworld-bff" \
    user_claim=sub \
    token_policies=helloworld-bff \
    token_ttl=90m \
    token_max_ttl=90m 2>&1 | tail -1

# Final summary.
green ""
green "Bootstrap complete. helloworld-bff will use:"
green "  - Valkey password:        bao read secret/apps/helloworld-bff/valkey"
green "  - SPIFFE-bound auth:      auth/jwt/role/helloworld-bff (token_ttl=90m)"
green "  - private_key_jwt PEM:    secret/keycloak/clients/helloworld-bff (set up separately)"
green ""
green "Re-run this script after any Valkey password rotation to refresh"
green "the OpenBao mirror; the BFF picks up the new password on its next"
green "session-store auth-failure retry (apps/helloworld-bff/session.go)."
green ""
