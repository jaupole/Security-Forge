#!/usr/bin/env bash
# Phase 7.2 — Wazuh deploy.
#
# Order:
#   1. Namespace (PSS=baseline)
#   2. NetworkPolicies
#   3. Pre-create the 4 Secrets (existingSecrets pattern — keeps passwords out
#      of values.yaml / git)
#   4. helm install / upgrade (vendored chart at vendor/wazuh/)
#   5. Wait for indexer → manager → dashboard Ready in that order

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS=wazuh
RELEASE=wazuh
CHART="$HERE/vendor/wazuh"
VALUES="$HERE/values.yaml"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. Namespace ─────────────────────────────────────────────────────
green "==> [1/5] namespace + PSS labels"
kubectl apply -f "$HERE/01-namespace.yaml"

# ─── 2. NetworkPolicies (apply BEFORE workloads — avoids race) ────────
green "==> [2/5] NetworkPolicies"
kubectl apply -f "$HERE/02-networkpolicies.yaml"

# ─── 3. Pre-create the 4 Secrets ──────────────────────────────────────
# Schema (per chart templates/secrets/*.yaml):
#   indexer:   username + password    ← chart defaults username="admin"
#   api:       username + password    ← chart defaults username="wazuh-wui"
#   dashboard: password
#   filebeat:  password
# We set username explicitly to match chart defaults so the chart's
# downstream env-var lookups match.
# Wazuh enforces password complexity (Error 5007 if violated): length 8–64,
# at least 1 upper / 1 lower / 1 digit / 1 special from .*+?=!&|<>(){}[]
#
# We deliberately exclude `|` and `&` from the special-char set even though
# Wazuh would accept them. Reason: the image's /etc/cont-init.d/1-config-filebeat
# uses sed with `|` as the delimiter to substitute INDEXER_PASSWORD into
# /etc/filebeat/filebeat.yml — `s|password:.*|password: '$INDEXER_PASSWORD'|g`.
# A `|` inside the password breaks the sed expression syntactically; with `set -e`
# at the top of the cont-init script, the substitution aborts and the SSL
# directives never get uncommented, so filebeat → indexer fails with x509
# (no ssl.certificate_authorities) and empty password (operator-backlog #23).
# `&` is a sed-replacement metacharacter (the whole match) that would also
# corrupt the substituted value. Keeping `.*+?=!` still satisfies Wazuh's
# "≥1 special" rule and is sed-safe.
gen_pw() {
    python3 - <<'PY'
import secrets, string
specials = ".*+?=!"
alphabet = string.ascii_letters + string.digits + specials
while True:
    pw = "".join(secrets.choice(alphabet) for _ in range(32))
    if (any(c.isupper() for c in pw) and any(c.islower() for c in pw)
        and any(c.isdigit() for c in pw) and any(c in specials for c in pw)):
        print(pw); break
PY
}

green "==> [3/5] pre-creating credentials Secrets (idempotent)"

create_or_keep() {
    local name="$1"; shift
    if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
        yellow "    secret/$name already exists — keeping (idempotent re-run)"
    else
        kubectl create secret generic -n "$NS" "$name" "$@" >/dev/null
        green  "    secret/$name created"
    fi
}

create_or_keep wazuh-indexer-creds  --from-literal=username=admin    --from-literal=password="$(gen_pw)"
create_or_keep wazuh-api-creds      --from-literal=username=wazuh-wui --from-literal=password="$(gen_pw)"
create_or_keep wazuh-dashboard-creds --from-literal=password="$(gen_pw)"
create_or_keep wazuh-filebeat-creds  --from-literal=password="$(gen_pw)"

kubectl -n "$NS" label secret \
    wazuh-indexer-creds wazuh-api-creds wazuh-dashboard-creds wazuh-filebeat-creds \
    secforge.platform/component=wazuh --overwrite >/dev/null

# ─── 4. helm install ──────────────────────────────────────────────────
green "==> [4/5] helm upgrade --install $RELEASE (vendored chart)"
helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NS" \
    -f "$VALUES" \
    --wait=false --timeout 10m

# ─── 5. Watch-for-Ready (indexer → manager → dashboard) ───────────────
green "==> [5/5] waiting for components Ready (indexer → manager → dashboard)"

green "    waiting for cert-bootstrap Job"
kubectl -n "$NS" wait --for=condition=Complete job/wazuh-certs-generator --timeout=180s 2>&1 | tail -1 || \
    yellow "    (cert-bootstrap watch timed out; continuing — may already be Complete)"

green "    waiting for indexer (StatefulSet) Ready"
kubectl -n "$NS" rollout status statefulset/wazuh-indexer --timeout=600s

green "    waiting for manager (StatefulSet) Ready"
kubectl -n "$NS" rollout status statefulset/wazuh-manager --timeout=600s

green "    waiting for dashboard (Deployment) Ready"
kubectl -n "$NS" rollout status deployment/wazuh-dashboard --timeout=300s

green ""
green "Wazuh stack deployed. Quick sanity:"
green "  kubectl -n $NS get pods"
green "  curl -sk https://wazuh.secforge.local/  # → dashboard login (admin / \$(kubectl -n $NS get secret wazuh-dashboard-creds -o jsonpath='{.data.password}' | base64 -d))"
