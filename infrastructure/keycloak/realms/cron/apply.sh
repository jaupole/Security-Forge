#!/usr/bin/env bash
# Phase 7d.1.b — apply BFF key rotator manifests.
#
# Builds the `bff-key-rotator-scripts` ConfigMap from the on-disk
# sources (so the script in `infrastructure/keycloak/realms/` and the
# in-pod copy stay in sync; same idiom as the secrets-guardrails-verify
# ConfigMap), then applies the YAML manifest.
#
# Pre-conditions:
#   1. infrastructure/openbao/policies/bff-key-rotator.hcl loaded:
#        BAO_TOKEN=hvs.xxx bash infrastructure/openbao/load-policies.sh
#   2. OpenBao JWT role configured:
#        BAO_TOKEN=hvs.xxx bash infrastructure/keycloak/realms/cron/configure-openbao-role.sh
#
# Idempotent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALMS_DIR="$(cd "$HERE/.." && pwd)"
LIB_DIR="$(cd "$HERE/../../_lib" && pwd)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 1. Sanity-check the source files exist.
for f in "$REALMS_DIR/rotate-bff-key.sh" \
         "$LIB_DIR/kcadm-auth.sh" \
         "$HERE/wrapper.sh"; do
    if [ ! -r "$f" ]; then
        red "missing source file: $f"
        exit 1
    fi
done

# 2. Copy the mkcert CA into `app` ns as Secret `openbao-ca-bundle` so
#    the rotator pod can verify OpenBao's serving cert (replaces an
#    earlier `curl -ksS` pattern; see ADR — no slot yet — and the
#    audit S1 fix). Same canonical pattern as
#    infrastructure/vault-secrets-operator/apply.sh.
green "==> copying mkcert CA into app as openbao-ca-bundle"
CA_PEM=$(kubectl get secret -n cert-manager mkcert-ca-key-pair \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [ -z "$CA_PEM" ]; then
    red "could not read mkcert-ca-key-pair from cert-manager namespace"
    exit 1
fi
kubectl create secret generic openbao-ca-bundle \
    -n app \
    --from-literal=ca.crt="$CA_PEM" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n app label secret openbao-ca-bundle \
    secforge.platform/component=bff-key-rotator \
    --overwrite >/dev/null

# 3. Build the scripts ConfigMap from on-disk sources. `kubectl create
#    configmap --dry-run=client -o yaml | kubectl apply -f -` is the
#    standard idempotent idiom for live-rebuilt ConfigMaps.
green "==> building bff-key-rotator-scripts ConfigMap from on-disk sources"
kubectl create configmap bff-key-rotator-scripts \
    --namespace=app \
    --from-file=rotate-bff-key.sh="$REALMS_DIR/rotate-bff-key.sh" \
    --from-file=kcadm-auth.sh="$LIB_DIR/kcadm-auth.sh" \
    --from-file=wrapper.sh="$HERE/wrapper.sh" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

# 4. Apply the manifest (RBAC, helper-conf ConfigMap, four CronJobs).
green "==> applying 01-rotate-bff-key.yaml"
kubectl apply -f "$HERE/01-rotate-bff-key.yaml"

green ""
green "BFF key rotator deployed."
green ""
green "Verify suspended state of placeholder CronJobs:"
green "  kubectl get cronjob -n app -l app.kubernetes.io/name=bff-key-rotator"
green ""
green "Trigger a one-shot manual rotation (production: run from host"
green "instead of the cron — see runbook docs/03-runbooks/bff-key-rotation.md):"
green "  kubectl create job -n app bff-key-rotator-manual-\$(date +%s) \\"
green "      --from=cronjob/bff-key-rotator-helloworld-bff"
green ""
