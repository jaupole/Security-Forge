#!/usr/bin/env bash
# 07r — Alertmanager email: Gmail app-password → Resend (one-shot migration).
#
# Closes the README-alerting "SMTP secret → OpenBao/VSO" hardening follow-up:
#   1. reloads the vso policy (now grants secret/observability/alertmanager-smtp)
#   2. upserts the alertmanager-vso Kubernetes auth role (also in 05j)
#   3. stages the Resend sending-only API key in OpenBao
#   4. applies the VSO binding (16-) and waits for the rendered Secret
#   5. applies the switched AlertmanagerConfig (13-) — Resend smarthost
#   6. sends a test alert and checks for Notify success
#   7. deletes the legacy alertmanager-smtp-gmail Secret
#
# Pre-conditions:
#   - openbao-root-token-tmp Secret in openbao ns (deploy-day ritual)
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

# Pre-flight
if ! kubectl -n "$NS_BAO" get secret openbao-root-token-tmp >/dev/null 2>&1; then
  red "ERROR: openbao-root-token-tmp Secret not found (deploy-day pre-condition)."; exit 1
fi

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

ROOT_TOKEN=$(kubectl -n "$NS_BAO" get secret openbao-root-token-tmp -o jsonpath='{.data.token}' | base64 -d)
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

# 6. End-to-end: test alert → Notify success in the Alertmanager log
green "==> sending test alert (expect one email from alerts@\${DOMAIN})"
sleep 15   # let the operator reload the Alertmanager config
kubectl -n "$NS" exec alertmanager-kps-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add \
  alertname=ResendMigrationTest severity=info \
  --annotation=summary='Alertmanager → Resend migration test — safe to ignore'
sleep 45
if kubectl -n "$NS" logs alertmanager-kps-alertmanager-0 -c alertmanager --since=2m \
     | grep -q 'Notify success'; then
  green "    Notify success — Resend path live"
else
  red "WARNING: no 'Notify success' in the last 2m of Alertmanager logs."
  red "Old Gmail Secret NOT deleted — inspect before finishing:"
  red "  kubectl -n $NS logs alertmanager-kps-alertmanager-0 -c alertmanager | grep -iE 'notify|smtp' | tail"
  exit 1
fi

# 7. Retire the legacy Gmail secret
green "==> deleting legacy alertmanager-smtp-gmail Secret"
kubectl -n "$NS" delete secret alertmanager-smtp-gmail --ignore-not-found

echo
green "✓ Alertmanager email now sends via Resend (alerts@ on the platform domain)."
yellow "REMEMBER: revoke the Gmail app password at myaccount.google.com/apppasswords."
