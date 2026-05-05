#!/usr/bin/env bash
# Phase 9.7 — render apps/helloworld-frontend/{index.html,app.js,style.css}
# into a ConfigMap. Re-run after editing any of those files.
#
# Why a script and not a checked-in YAML: kubectl create configmap --from-file
# embeds the files cleanly without YAML quoting hell. The file is regenerated
# on every run so reviews stay readable in the source files, not the YAML.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/.."

kubectl create configmap helloworld-frontend \
    --namespace=app \
    --from-file=index.html="$SRC/index.html" \
    --from-file=app.js="$SRC/app.js" \
    --from-file=style.css="$SRC/style.css" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - \
        app.kubernetes.io/name=helloworld-frontend \
        app.kubernetes.io/part-of=helloworld \
        secforge.platform/component=helloworld-frontend \
        --dry-run=client -o yaml | \
    kubectl apply -f -

# Separate ConfigMap for the nginx server config — mounted at
# /etc/nginx/conf.d/default.conf so sub_filter substitutes the per-request
# CSP nonce (X-CSP-Nonce header from the BFF) into served HTML.
kubectl create configmap helloworld-frontend-nginx-conf \
    --namespace=app \
    --from-file=default.conf="$SRC/nginx-default.conf" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - \
        app.kubernetes.io/name=helloworld-frontend \
        app.kubernetes.io/part-of=helloworld \
        secforge.platform/component=helloworld-frontend \
        --dry-run=client -o yaml | \
    kubectl apply -f -

echo "ConfigMaps updated: helloworld-frontend (assets) + helloworld-frontend-nginx-conf"
