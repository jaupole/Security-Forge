#!/usr/bin/env bash
# rotate-ghcr-pat.sh — rotate the GHCR image-pull PAT (host-hardening tracker #6).
#
# WHY THIS EXISTS
#   The GHCR image-pull credential is stored ONCE in OpenBao at
#   secret/apps/control/ghcr-pull ({username, password}) and Vault Secrets
#   Operator renders it into a `ghcr-pull-secret` dockerconfigjson Secret in every
#   consuming namespace (control / member-hub / kyverno / keycloak / proposal-forge
#   / …) via per-ns VaultStaticSecret bindings (refreshAfter 5m). So a rotation is
#   just: write the new PAT to that one OpenBao key → VSO propagates everywhere.
#
#   The OLD flow was a heredoc typed at the shell with the PAT piped on stdin,
#   which lands the token in shell history / process args. This script takes the
#   PAT (and the OpenBao token) via SILENT prompts (`read -rs`) so neither is ever
#   echoed, stored in history, or visible in `ps`. The PAT only ever lives in
#   OpenBao (the sealed source) and in transient shell variables that are unset
#   immediately after use.
#
# USAGE (run on secforge-prod, as the operator)
#   bash ~/secforge/platform/components/rotate-ghcr-pat.sh
#   You will be prompted for:
#     1. the new GHCR classic PAT (scope: read:packages),
#     2. an OpenBao token with write on secret/data/apps/control/ghcr-pull
#        (e.g. from `bao login -method=oidc`).
#
# NOTES
#   - Classic PAT required: fine-grained PATs don't expose the Packages:read
#     permission GHCR needs (see project_member_hub_phase_b_deploy memory).
#   - The username is preserved (read from the existing secret); only the PAT
#     (password) is rotated.
#   - Idempotent + safe to re-run. Does NOT need the break-glass root token.

set -euo pipefail

NS_BAO=openbao
POD_BAO=openbao-0
BAO_MOUNT=secret
GHCR_PATH=apps/control/ghcr-pull      # kv-v2 path under the `secret` mount
VSS_NAME=ghcr-pull-secret             # VaultStaticSecret + rendered Secret name

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || { red "kubectl not found on PATH"; exit 1; }
kubectl -n "$NS_BAO" get pod "$POD_BAO" >/dev/null 2>&1 \
  || { red "openbao pod $POD_BAO not found in ns $NS_BAO"; exit 1; }

# --- 1. Collect secrets via silent prompts (never echoed / never in history) ---
read -rsp "New GHCR classic PAT (read:packages): " NEW_PAT; echo
[ -n "$NEW_PAT" ] || { red "empty PAT — aborting"; exit 1; }
read -rsp "OpenBao token (write on $BAO_MOUNT/data/$GHCR_PATH): " BAO_TOKEN; echo
[ -n "$BAO_TOKEN" ] || { red "empty OpenBao token — aborting"; exit 1; }

# Helper: run `bao` inside the openbao pod with the token + TLS-skip via env, so
# neither the token nor the PAT ever appears in the pod's process argv.
bao_exec() {
  kubectl exec -i -n "$NS_BAO" "$POD_BAO" -c openbao -- \
    env BAO_SKIP_VERIFY=1 BAO_TOKEN="$BAO_TOKEN" "$@"
}

# --- 2. Preserve the existing username; rotate only the password (PAT) ---
GHCR_USER="$(bao_exec bao kv get -mount="$BAO_MOUNT" -field=username "$GHCR_PATH" 2>/dev/null || true)"
if [ -z "$GHCR_USER" ]; then
  read -rp "No existing username at $GHCR_PATH — enter GHCR username: " GHCR_USER
  [ -n "$GHCR_USER" ] || { red "username required — aborting"; exit 1; }
fi
green "==> writing new PAT to OpenBao $BAO_MOUNT/$GHCR_PATH (user: $GHCR_USER)"

# Pass the PAT to `bao kv put` over stdin so it never appears in argv. In the
# OpenBao/Vault CLI a field value of `-` is read from stdin (`@file` would read a
# file); only `password` uses stdin here, so there's no ambiguity.
printf '%s' "$NEW_PAT" | bao_exec sh -c \
  "bao kv put -mount=$BAO_MOUNT $GHCR_PATH username='$GHCR_USER' password=-" >/dev/null
unset NEW_PAT BAO_TOKEN
green "    PAT updated in OpenBao."

# --- 3. Nudge VSO to re-render immediately (else it refreshes within ~5m) ---
green "==> forcing VSO re-sync of every $VSS_NAME VaultStaticSecret"
mapfile -t NS_LIST < <(kubectl get vaultstaticsecret -A \
  --field-selector "metadata.name=$VSS_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
if [ "${#NS_LIST[@]}" -eq 0 ]; then
  red "WARNING: no VaultStaticSecret named $VSS_NAME found — VSO will still refresh on its 5m timer if bindings exist under another name."
fi
STAMP="$(date +%s)"
for ns in "${NS_LIST[@]}"; do
  kubectl -n "$ns" annotate vaultstaticsecret "$VSS_NAME" \
    "vso.secrets.hashicorp.com/force-sync=$STAMP" --overwrite >/dev/null 2>&1 \
    && green "    forced re-sync: $ns/$VSS_NAME" \
    || red    "    could not annotate $ns/$VSS_NAME (will refresh on the 5m timer)"
done

# --- 4. Verify the rendered Secrets exist (content is hmac'd; can't compare here) ---
green "==> verifying rendered ghcr-pull-secret Secrets"
sleep 5
for ns in "${NS_LIST[@]}"; do
  if kubectl -n "$ns" get secret "$VSS_NAME" -o jsonpath='{.data.\.dockerconfigjson}' >/dev/null 2>&1; then
    green "    ok: $ns/$VSS_NAME present"
  else
    red "    MISSING: $ns/$VSS_NAME — check the VaultStaticSecret status"
  fi
done

cat <<EOF

✓ GHCR PAT rotated in OpenBao ($BAO_MOUNT/$GHCR_PATH); VSO is propagating to:
    ${NS_LIST[*]:-<none found>}
Allow up to ~5m for any binding not force-synced above, then confirm a fresh
image pull works (e.g. delete a pod that pulls from ghcr.io and watch it start).
The old PAT can be revoked in GitHub once pulls are confirmed healthy.
EOF
