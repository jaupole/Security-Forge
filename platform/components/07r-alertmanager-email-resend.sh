#!/usr/bin/env bash
# 07r — Alertmanager email: Gmail app-password → Resend (one-shot migration).
#
# Closes the README-alerting "SMTP secret → OpenBao/VSO" hardening follow-up:
#   1. reloads the vso policy (now grants secret/observability/alertmanager-smtp)
#   2. upserts the alertmanager-vso Kubernetes auth role (also in 05j)
#   3. stages the Resend sending-only API key in OpenBao
#   4. applies the VSO binding (16-) and waits for the rendered Secret
#   5. applies the switched AlertmanagerConfig (13-) — Resend smarthost
#   6. waits for the config reload, sends a test alert, verifies via counters
#   7. deletes the legacy alertmanager-smtp-gmail Secret
#
# Pre-conditions:
#   - a privileged OpenBao token in ONE of (checked in this order):
#       openbao-operator-token-tmp   — PREFERRED: your own OIDC-admin token.
#         Log in at https://bao.${DOMAIN} (tailnet) with the jason.upole
#         account (OIDC role `admin` → admin policy), copy the token from
#         the UI, then:
#           kubectl -n openbao create secret generic openbao-operator-token-tmp \
#             --from-literal=token=<the token>
#         Attributed to your account in the audit log, TTL-bounded, no
#         Shamir ceremony. Delete the secret when done.
#       openbao-root-token-tmp       — fallback: the deploy-day root ritual
#         (needed only on a fresh DR cluster where OIDC auth isn't up yet).
#   - a NEW Resend API key with SENDING-ONLY scope, created in the Resend
#     dashboard (resend.com → API Keys → Create → permission "Sending access").
#     NEVER reuse Control's platform key — this one must be independently
#     revocable. Pass it as a file: 07r-alertmanager-email-resend.sh /path/key
#     (file is NOT deleted — operator shreds it), or interactively at the prompt.
#   - AFTERWARDS: revoke the old Gmail app password at
#     myaccount.google.com/apppasswords (it also transited a chat transcript
#     on first setup — revoking closes that exposure too).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"

NS=observability
NS_BAO=openbao
POD_BAO=openbao-0

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# Pre-flight — operator OIDC token preferred, root token as DR fallback.
TOKEN_SECRET=""
for cand in openbao-operator-token-tmp openbao-root-token-tmp; do
  if kubectl -n "$NS_BAO" get secret "$cand" >/dev/null 2>&1; then
    TOKEN_SECRET="$cand"; break
  fi
done
if [ -z "$TOKEN_SECRET" ]; then
  red "ERROR: no privileged-token Secret found."
  red "Preferred: log in at the OpenBao UI (OIDC admin) and stage your token as"
  red "  kubectl -n $NS_BAO create secret generic openbao-operator-token-tmp --from-literal=token=<token>"
  exit 1
fi
green "==> using token from Secret $TOKEN_SECRET"

# Resend key: file arg or interactive prompt (never an env var — Kyverno-shaped
# hygiene, and it would land in shell history / process listings).
if [ "${1:-}" != "" ]; then
  [ -r "$1" ] || { red "ERROR: key file '$1' not readable"; exit 1; }
  RESEND_KEY="$(tr -d '[:space:]' < "$1")"
else
  read -rsp "Resend sending-only API key (re_...): " RESEND_KEY; echo
fi
case "$RESEND_KEY" in
  re_*) : ;;
  *) red "ERROR: that does not look like a Resend API key (expected re_ prefix)"; exit 1 ;;
esac

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret "$TOKEN_SECRET" -o jsonpath='{.data.token}' | base64 -d)
bao() {
  kubectl exec -i -n "$NS_BAO" "$POD_BAO" -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$ROOT_TOKEN" "$@"
}

# 1. Reload vso policy (adds the alertmanager-smtp path)
green "==> re-load vso policy"
kubectl -n "$NS_BAO" cp "$PLATFORM_DIR/manifests/openbao/policies/vso.hcl" "$POD_BAO:/tmp/vso.hcl" -c openbao
bao bao policy write vso /tmp/vso.hcl 2>&1 | tail -1
kubectl exec -n "$NS_BAO" "$POD_BAO" -c openbao -- rm -f /tmp/vso.hcl

# 2. K8s auth role (mirrors the 05j APP_ROLES row)
K8S_AUDIENCE="https://kubernetes.default.svc.cluster.local"
green "==> write OpenBao K8s auth role: alertmanager-vso"
bao bao write auth/kubernetes/role/alertmanager-vso \
  bound_service_account_names="alertmanager-vso" \
  bound_service_account_namespaces="$NS" \
  audience="$K8S_AUDIENCE" \
  policies="vso" \
  ttl="1h" \
  max_ttl="24h" 2>&1 | tail -1

# 3. Stage the key (stdin, so it never appears in an argv/process listing)
green "==> stage key at secret/observability/alertmanager-smtp"
printf '%s' "$RESEND_KEY" | bao bao kv put secret/observability/alertmanager-smtp password=- >/dev/null
unset RESEND_KEY ROOT_TOKEN

# 4. VSO binding + wait for render
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/16-alertmanager-smtp-vso-binding.yaml"
green "==> waiting for VSO to render alertmanager-smtp-resend (up to 60s)"
for i in $(seq 1 12); do
  if kubectl -n "$NS" get secret alertmanager-smtp-resend >/dev/null 2>&1; then
    green "    rendered after $((i*5))s"; break
  fi
  if [ "$i" -eq 12 ]; then
    red "ERROR: VSO did not render alertmanager-smtp-resend within 60s"; exit 1
  fi
  sleep 5
done

# 5. Switched AlertmanagerConfig (safe now the Secret exists)
"$LIB/apply-manifest.sh" "$PLATFORM_DIR/manifests/observability/13-alertmanager-email.yaml"

# 6. End-to-end: wait for the config reload, fire a test alert, judge by counters.
#    NOT by grepping "Notify success" — that line is debug-level (invisible at
#    the default info log level), and the operator's config reload lands ~1min
#    after step 5, so a fixed sleep fires the test alert into the OLD config.
#    Both made the 2026-10-13 run report failure on a working Resend path.
AM_POD=alertmanager-kps-alertmanager-0
am_exec() { kubectl -n "$NS" exec "$AM_POD" -c alertmanager -- "$@"; }
am_metric() {   # sum of one counter family over the email integration
  am_exec wget -qO- http://localhost:9093/metrics 2>/dev/null | awk -v m="$1" '
    index($1, m "{integration=\"email\"") == 1 { s += $2 } END { printf "%d", s }'
}
am_reload_ts() {
  am_exec wget -qO- http://localhost:9093/metrics 2>/dev/null | awk '
    $1 == "alertmanager_config_last_reload_success_timestamp_seconds" { printf "%d", $2 }'
}

applied_at=$(date +%s)
green "==> waiting for Alertmanager to reload the switched config (up to 3m)"
for i in $(seq 1 36); do
  ts=$(am_reload_ts); ts=${ts:-0}
  if [ "$ts" -ge "$applied_at" ]; then green "    reloaded after $((i*5))s"; break; fi
  if [ "$i" -eq 36 ]; then
    red "ERROR: Alertmanager has not reloaded the config in 3m."
    red "Old Gmail Secret NOT deleted — inspect the operator / config-reloader:"
    red "  kubectl -n $NS logs $AM_POD -c config-reloader --tail=50"
    exit 1
  fi
  sleep 5
done

sent_before=$(am_metric alertmanager_notifications_total)
failed_before=$(am_metric alertmanager_notifications_failed_total)
green "==> sending test alert (expect one email from alerts@\${DOMAIN})"
am_exec amtool --alertmanager.url=http://localhost:9093 alert add   alertname=ResendMigrationTest severity=info   --annotation=summary='Alertmanager → Resend migration test — safe to ignore'   2>&1 | grep -v 'moving to a new parser' || true

green "==> waiting for the email notification (group_wait + send, up to 2m)"
for i in $(seq 1 24); do
  sleep 5
  sent_after=$(am_metric alertmanager_notifications_total)
  failed_after=$(am_metric alertmanager_notifications_failed_total)
  if [ "$failed_after" -gt "$failed_before" ]; then
    red "ERROR: email notification FAILED (failed_total ${failed_before}→${failed_after})."
    red "Old Gmail Secret NOT deleted — inspect before finishing:"
    red "  kubectl -n $NS logs $AM_POD -c alertmanager | grep -iE 'notify|smtp' | tail"
    exit 1
  fi
  if [ "$sent_after" -gt "$sent_before" ]; then
    green "    email notification sent (notifications_total ${sent_before}→${sent_after}, failed unchanged) — Resend path live"
    break
  fi
  if [ "$i" -eq 24 ]; then
    red "WARNING: no email notification counted in 2m (${sent_before}→${sent_after})."
    red "Old Gmail Secret NOT deleted — check the receiver routing before finishing:"
    red "  kubectl -n $NS exec $AM_POD -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 config routes"
    exit 1
  fi
done

# 7. Retire the legacy Gmail secret
green "==> deleting legacy alertmanager-smtp-gmail Secret"
kubectl -n "$NS" delete secret alertmanager-smtp-gmail --ignore-not-found

echo
green "✓ Alertmanager email now sends via Resend (alerts@ on the platform domain)."
yellow "REMEMBER: revoke the Gmail app password at myaccount.google.com/apppasswords."
