#!/usr/bin/env bash
# openbao-token.sh — resolve a privileged OpenBao token for one-shot staging
# steps (policy reload, K8s auth role, kv put) in the component scripts.
#
# Source this file, then call `resolve_bao_token`. It sets:
#   TOKEN_SECRET  — name of the Secret found in $NS_BAO, or "" when none exists
#   ROOT_TOKEN    — the token value (callers `unset ROOT_TOKEN` when done)
# and defines `bao` (kubectl exec into the OpenBao pod with BAO_TOKEN set).
#
# Order of preference (same as 07r-alertmanager-email-resend.sh):
#   openbao-operator-token-tmp — PREFERRED: the operator's own OIDC token.
#       Log in at https://bao.${DOMAIN} (OIDC, role admin), copy the token, then
#         printf '%s' "$t" | kubectl -n openbao create secret generic \
#           openbao-operator-token-tmp --from-file=token=/dev/stdin
#       Attributed to the operator in the audit log, TTL-bounded, no Shamir
#       ceremony. Delete the Secret when done.
#   openbao-root-token-tmp     — DR fallback only (fresh cluster, OIDC not up).
#
# Scripts whose OpenBao staging is one-time bootstrap (07e, 07f, 09a) treat a
# missing token as "skip staging" when the VSO-rendered Secret already exists,
# so a plain chart roll never needs a privileged token.
NS_BAO="${NS_BAO:-openbao}"
POD_BAO="${POD_BAO:-openbao-0}"

resolve_bao_token() {
  TOKEN_SECRET=""
  local cand
  for cand in openbao-operator-token-tmp openbao-root-token-tmp; do
    if kubectl -n "$NS_BAO" get secret "$cand" >/dev/null 2>&1; then
      TOKEN_SECRET="$cand"; break
    fi
  done
  [ -n "$TOKEN_SECRET" ] || return 0
  ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret "$TOKEN_SECRET" -o jsonpath='{.data.token}' | base64 -d)
  bao() {
    kubectl exec -i -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
  }
}

# bao_token_required <rendered-ns> <rendered-secret>
# Call after resolve_bao_token. Exit 0 with SKIP_STAGING=1 when no token is
# present but the rendered Secret already exists; exit 1 with guidance when
# neither is available.
bao_token_required() {
  local ns="$1" name="$2"
  SKIP_STAGING=""
  if [ -n "$TOKEN_SECRET" ]; then
    printf '\033[32m%s\033[0m\n' "==> using OpenBao token from Secret $TOKEN_SECRET"
    return 0
  fi
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    printf '\033[33m%s\033[0m\n' "==> no privileged OpenBao token Secret; $ns/$name is already rendered — skipping OpenBao staging (stage openbao-operator-token-tmp to re-run it)"
    SKIP_STAGING=1
    return 0
  fi
  printf '\033[31m%s\033[0m\n' "ERROR: no privileged OpenBao token Secret and $ns/$name is not rendered yet." >&2
  printf '\033[31m%s\033[0m\n' "Preferred: log in at the OpenBao UI (OIDC, role admin), copy your token, then:" >&2
  printf '\033[31m%s\033[0m\n' "  printf '%s' \"\$t\" | kubectl -n $NS_BAO create secret generic openbao-operator-token-tmp --from-file=token=/dev/stdin" >&2
  printf '\033[31m%s\033[0m\n' "(openbao-root-token-tmp is the DR-only fallback.)" >&2
  exit 1
}
