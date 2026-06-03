#!/usr/bin/env bash
# 06a — Istio ingress gateway. Replaces the EOL ingress-nginx controller
# (kubernetes/ingress-nginx archived 2026-03-24). See ADR-0032 and
# docs/03-runbooks/ingress-nginx-to-istio-cutover.md.
#
# Runs AFTER 06-istio.sh (istiod/ztunnel/cni). Stands up a dedicated Istio
# ingress gateway in the `istio-ingress` namespace that terminates TLS for every
# *.secforge.dev host with the cert-manager wildcard, routes per-host, and
# enforces per-host edge authorization (tailnet allowlists, the auth /admin
# split, the portal admin/system deny-list, the billing Stripe-IP allowlist).
#
# ── Reproducibility notes (READ before editing) ─────────────────────────────
#   * The istio/gateway chart has NO hostPort value, and its Deployment template
#     ships `image: auto` (istiod injects the proxy at POD creation). So this
#     script does two non-obvious things after `helm upgrade`:
#       1. patches the Deployment to add the host port binding (default 80/443),
#       2. relies on values/istio-gateway.yaml pinning the injected proxy by
#          digest via sidecar.istio.io/proxyImage (so require-image-digest +
#          restrict-image-registries pass — both have autogen=pod-only; see
#          policies 08/09).
#     A bare `helm upgrade` OUTSIDE this script drops the hostPort patch and
#     takes the gateway off :80/:443. Always reconcile through this component.
#   * GREENFIELD: deploys straight on 80/443 (no nginx present).
#     ALONGSIDE MIGRATION: set GATEWAY_HOSTPORT_HTTP=8080 GATEWAY_HOSTPORT_HTTPS=8443
#     to run beside ingress-nginx, then follow the cutover runbook.
#
# Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/istio-gateway"
NS=istio-ingress

GATEWAY_CHART_VER="${ISTIO_GATEWAY_CHART_VER:-1.29.2}"   # match istiod
HP_HTTP="${GATEWAY_HOSTPORT_HTTP:-80}"
HP_HTTPS="${GATEWAY_HOSTPORT_HTTPS:-443}"

echo "════════════════════════════════════════════════════════════"
echo "  06a — Istio ingress gateway (hostPort ${HP_HTTP}/${HP_HTTPS})"
echo "════════════════════════════════════════════════════════════"

# HTTP backends enrolled in the ambient mesh so the gateway→backend hop is HBONE
# mTLS. keycloak/openbao are NOT here — they terminate their own app-TLS.
AMBIENT_BACKENDS=(control member-hub observability wazuh proposal-forge)

# ─── 1. Namespace, wildcard cert, NetworkPolicies ──────────────────────────
echo ">>> [1] namespace + wildcard Certificate + istiod XDS netpol + backend allows"
kubectl apply -f "$M/00-namespace.yaml"
kubectl apply -f "$M/01-wildcard-cert.yaml"
kubectl apply -f "$M/05-netpol-istiod.yaml"
# Backend allows MUST exist before ambient enrollment: an ambient backend
# receives the gateway's inbound over ztunnel's HBONE port 15008 (not the app
# port), and 25-backend-netpols.yaml opens 15008 for the ambient backends.
kubectl apply -f "$M/25-backend-netpols.yaml"

echo ">>> [1b] enroll HTTP backends into ambient (gateway→backend mTLS over HBONE)"
# Kyverno policy keeps the ambient label on these app-owned namespaces even if an
# app re-applies its namespace (drift-proof); the loop is the immediate enroll.
kubectl apply -f "$M/26-mutate-ambient-backends.yaml"
for ns in "${AMBIENT_BACKENDS[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 && \
    kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite || \
    echo "    (ns $ns not present yet — skip)"
done
kubectl -n cert-manager wait --for=condition=Ready certificate/secforge-wildcard \
  -n "$NS" --timeout=180s 2>/dev/null || \
  kubectl -n "$NS" wait --for=condition=Ready certificate/secforge-wildcard --timeout=180s || true

# ─── 2. Gateway proxy (istio/gateway Helm chart) ───────────────────────────
echo ">>> [2] helm install istio/gateway (${GATEWAY_CHART_VER})"
"$LIB/install-helm.sh" \
  --release istio-ingress --namespace "$NS" \
  --repo-name istio --repo-url https://istio-release.storage.googleapis.com/charts \
  --chart istio/gateway --version "$GATEWAY_CHART_VER" \
  --values "$PLATFORM_DIR/values/istio-gateway.yaml"

# ─── 3. hostPort patch (chart has no hostPort value) ───────────────────────
echo ">>> [3] patch Deployment hostPort -> ${HP_HTTP}/${HP_HTTPS}"
kubectl -n "$NS" patch deploy istio-ingress --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"istio-proxy\",\"ports\":[{\"name\":\"http\",\"containerPort\":80,\"hostPort\":${HP_HTTP},\"protocol\":\"TCP\"},{\"name\":\"https\",\"containerPort\":443,\"hostPort\":${HP_HTTPS},\"protocol\":\"TCP\"}]}]}}}}"
kubectl -n "$NS" rollout status deploy/istio-ingress --timeout=180s

# ─── 4. Routing / authz / TLS / headers ────────────────────────────────────
echo ">>> [4] Gateway + VirtualServices + AuthorizationPolicies + DestinationRules + headers"
kubectl apply -f "$M/10-gateway.yaml"
kubectl apply -f "$M/20-virtualservices.yaml"
kubectl apply -f "$M/30-authorizationpolicies.yaml"
kubectl apply -f "$M/40-destinationrules.yaml"
kubectl apply -f "$M/50-envoyfilter-headers.yaml"

# ─── 5. Verify ─────────────────────────────────────────────────────────────
echo ">>> [5] verify gateway Ready + 80/443 listeners"
kubectl -n "$NS" rollout status deploy/istio-ingress --timeout=60s
GWPOD=$(kubectl -n "$NS" get pod --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
LISTENERS=$(kubectl -n "$NS" exec "$GWPOD" -c istio-proxy -- pilot-agent request GET listeners 2>/dev/null | grep -oE '0.0.0.0:(80|443)' | sort -u | tr '\n' ' ')
echo "    listeners: ${LISTENERS:-<none>}"
[[ "$LISTENERS" == *"0.0.0.0:80"* && "$LISTENERS" == *"0.0.0.0:443"* ]] || {
  echo "WARN: gateway is not listening on 80+443 yet — check the Gateway selector (istio: ingress)" >&2
}

cat <<EOF

✓ Istio gateway deployed (hostPort ${HP_HTTP}/${HP_HTTPS}).

  Validate EXTERNALLY (the node cannot hairpin to its own public IP on a
  hostPort — node-local curls give false negatives):
    curl -k --resolve members.secforge.dev:443:<PUBLIC_IP> https://members.secforge.dev/   # 200
    curl -k --resolve grafana.secforge.dev:443:<PUBLIC_IP> https://grafana.secforge.dev/   # 403 off-tailnet

  Migrating from a live ingress-nginx? See
  docs/03-runbooks/ingress-nginx-to-istio-cutover.md — the cutover is a
  deliberate :80/:443 hand-off (nginx grace-period fix + stale-DNAT cleanup).
EOF
