#!/usr/bin/env bash
# 06a — Istio ingress gateways (two-plane edge: public NIC + tailnet NIC).
#
# Codifies the edge that was previously created out-of-band — the public gateway
# was a drifted istio/gateway Helm release (STATUS=failed, hostIP binding left as
# an uncommitted `kubectl patch`); the tailnet gateway was a hand-applied
# Deployment. Both are now self-contained manifests in manifests/istio-ingress/,
# applied here so a from-scratch rebuild restores a working ingress (closes the
# Tier-2 DR gap — operator-backlog #64). See ADR-0032 + manifests/istio-ingress/README.md.
#
# Requires: 06-istio (istiod) must be up — it injects the gateway proxy.
#
# TAILNET PLANE DEPENDENCY: the tailnet gateway binds hostPort 80/443 to
# ${TAILNET_IP} (the node's Tailscale IP), which only exists after 10-tailscale
# has run. If this runs first, the PUBLIC gateway comes up fine but the
# istio-ingress-tailnet pod stays NotReady until Tailscale is up — then bounce it:
#   kubectl -n istio-ingress rollout restart deploy/istio-ingress-tailnet
#
# ONE-TIME LIVE MIGRATION (existing cluster only): the public gateway is still a
# (failed) Helm release there. Remove it once so this manifest is the sole owner:
#   helm uninstall istio-ingress -n istio-ingress
# Skip on a fresh rebuild — no release exists. See 11-public-gateway.yaml header.
#
# Idempotent (kubectl apply via the envsubst wrapper).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests/istio-ingress"

# Order: gateways (Deployments + Gateway CRs) before the VirtualServices that
# bind to them; DestinationRules / EnvoyFilter / AuthorizationPolicies after.
# Public first (no Tailscale dependency), then tailnet.
"$LIB/apply-manifest.sh" \
  "$M/11-public-gateway.yaml" \
  "$M/10-tailnet-gateway.yaml" \
  "$M/20-virtualservices.yaml" \
  "$M/30-destinationrules.yaml" \
  "$M/40-envoyfilter-security-headers.yaml" \
  "$M/50-authorizationpolicies.yaml"

echo
echo "✓ Istio ingress gateways applied (public + tailnet edge + routing CRs)."
echo
echo "Verify:"
echo "  kubectl -n istio-ingress get deploy,svc,gateway,virtualservice"
echo "  kubectl -n istio-ingress get pods           # both gateways Ready?"
echo
echo "If istio-ingress-tailnet is NotReady, confirm 10-tailscale has run, then:"
echo "  kubectl -n istio-ingress rollout restart deploy/istio-ingress-tailnet"
echo
