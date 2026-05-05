#!/usr/bin/env bash
# operator-backlog #13 (closed 2026-05-05) — migrate the helloworld-bff's
# Valkey AUTH password from K8s Secret + env var to OpenBao at
# secret/data/apps/helloworld-bff/valkey:password.
#
# The BFF (apps/helloworld-bff/main.go) fetches this at startup via
# apps/lib/secrets/ Client.GetField(ctx, "valkey", "password") — once
# this script + the policy reload run, the BFF can be redeployed without
# the BFF_VALKEY_PASSWORD env var or the secforge.local/legacy-secret-env
# annotation.
#
# What this does:
#   1. Reads the existing K8s Secret app/helloworld-bff-valkey:password
#      (the source of truth before the migration).
#   2. Writes it to OpenBao KV-v2 at secret/data/apps/helloworld-bff/valkey
#      with field name `password`.
#   3. Reload the helloworld-bff policy (which now allows the new path).
#   4. Verify the BFF's JWT auth role still has token_ttl > credential
#      default_ttl per the Phase 9 retro lesson; if it's at the old
#      10m default, bump.
#
# Prerequisites:
#   - operator authenticated to OpenBao as admin (OIDC):
#       bao login -method=oidc role=admin
#   - kubectl context on the local cluster
#   - K8s Secret app/helloworld-bff-valkey exists with key `password`
#
# Idempotent: re-running overwrites the KV value (which is fine if the
# upstream Valkey password rotates — re-run after each Valkey rotation).
#
# Usage:
#   bash infrastructure/helloworld/migrate-valkey-pw-to-bao.sh

set -euo pipefail

NS_APP=app
SECRET_NAME=helloworld-bff-valkey
KV_PATH=secret/data/apps/helloworld-bff/valkey
ROLE=helloworld-bff
POLICY=helloworld-bff
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Pre-flight.
if ! command -v bao >/dev/null; then
    red "bao CLI not on PATH (expected at ~/.local/bin/bao per memory note)"
    exit 1
fi
if ! bao token lookup-self >/dev/null 2>&1; then
    red "bao not logged in. Run: bao login -method=oidc role=admin"
    exit 1
fi
if ! kubectl get secret -n "$NS_APP" "$SECRET_NAME" >/dev/null 2>&1; then
    red "K8s Secret $NS_APP/$SECRET_NAME not found — nothing to migrate."
    exit 1
fi

# 2. Read the K8s Secret password.
green "==> reading $NS_APP/$SECRET_NAME:password from K8s"
PW=$(kubectl get secret -n "$NS_APP" "$SECRET_NAME" -o jsonpath='{.data.password}' | base64 -d)
if [ -z "$PW" ]; then
    red "    K8s Secret $NS_APP/$SECRET_NAME has empty .data.password"
    exit 1
fi
green "    read $(printf '%s' "$PW" | wc -c) bytes"

# 3. Write to OpenBao KV-v2.
green "==> writing $KV_PATH (field=password)"
# Pipe the value via stdin so it never appears in command-line args.
printf '%s' "$PW" | bao kv put "$KV_PATH" password=- >/dev/null
unset PW
green "    KV write succeeded"

# 4. Reload the helloworld-bff policy (extends to apps/helloworld-bff/+).
green "==> reloading policy $POLICY"
POLICY_FILE="$HERE/../openbao/policies/${POLICY}.hcl"
if [ ! -f "$POLICY_FILE" ]; then
    red "    policy file missing: $POLICY_FILE"
    exit 1
fi
bao policy write "$POLICY" "$POLICY_FILE" >/dev/null
green "    policy reloaded"

# 5. Verify JWT auth role token_ttl > credential default_ttl per Phase 9 retro.
#    The BFF's database creds default_ttl is 1h (helloworld-app-readwrite,
#    inherited from helloworld-backend-readwrite); token_ttl should be ≥ 90m.
green "==> verifying auth/jwt/role/$ROLE token_ttl"
TOKEN_TTL_S=$(bao read -format=json "auth/jwt/role/$ROLE" 2>/dev/null | jq -r '.data.token_ttl // 0')
if [ "$TOKEN_TTL_S" -lt 5400 ]; then
    yellow "    token_ttl=${TOKEN_TTL_S}s (< 90m) — bumping to 90m to honor Phase 9 retro rule"
    bao write "auth/jwt/role/$ROLE" \
        role_type=jwt \
        user_claim=sub \
        bound_audiences=openbao \
        bound_subject="spiffe://secforge.local/ns/app/sa/$ROLE" \
        bound_issuer="https://oidc.spire.svc.cluster.local" \
        token_policies="$POLICY" \
        token_ttl=90m \
        token_max_ttl=2h >/dev/null
    green "    token_ttl now 90m"
else
    green "    token_ttl=${TOKEN_TTL_S}s (≥ 90m) — already meets the rule"
fi

# 6. Sanity-read the new path with the BFF's role to prove the policy
#    works. Using the host-bao with admin token is sufficient validation
#    that the path exists; the BFF's JWT-SVID-bound read is exercised
#    when the next BFF pod starts.
green "==> sanity-read the KV path"
if bao kv get -format=json "$KV_PATH" 2>/dev/null | jq -e '.data.data.password' >/dev/null; then
    green "    KV value reads back successfully"
else
    red "    KV read failed — check policy + path"
    exit 1
fi

green ""
green "Migration complete. Next steps:"
green "  1. Rebuild + redeploy helloworld-bff:"
green "       bash apps/helloworld-bff/build.sh"
green "       kubectl rollout restart -n app deployment/helloworld-bff"
green "  2. Confirm BFF starts cleanly + emits 'valkey password loaded from openbao' INFO line:"
green "       kubectl logs -n app deployment/helloworld-bff --tail=20 | grep valkey"
green "  3. Once verified working, the K8s Secret $NS_APP/$SECRET_NAME can be deleted."
green ""
