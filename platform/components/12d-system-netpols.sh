#!/usr/bin/env bash
# 12d — default-deny NetworkPolicies for the system namespaces (audit H-4.14).
#
# Every application namespace is default-deny, but kube-system, istio-system, and
# topolvm-system shipped with ZERO NetworkPolicy. This applies the ingress-only
# default-deny + the precise allow rules each namespace needs. It makes the
# hardening durable across a cluster rebuild (the policies were first applied by
# hand 2026-05-31; this wires them into the deploy so a rebuild re-applies them).
#
# Design + rationale (the cni0 source-IP convention, DNS-safety proof, per-ns
# verification): docs/03-runbooks/system-ns-netpol-apply.md.
#
# ORDER IS LOAD-BEARING for kube-system: apply the ALLOW policies (CoreDNS :53
# from all, CoreDNS metrics + kubelet probes, metrics-server) BEFORE the
# default-deny, so cluster DNS is never black-holed. istio-system and
# topolvm-system ship allows + default-deny in one file, applied together.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
NP="$PLATFORM_DIR/manifests/system-netpol"

green() { printf '\033[32m%s\033[0m\n' "$*"; }

# kube-system — allows FIRST, then default-deny (DNS-safe ordering).
green "==> kube-system: allow policies (CoreDNS :53/metrics/probes, metrics-server)"
"$LIB/apply-manifest.sh" "$NP/kube-system-allows.yaml"
green "==> kube-system: default-deny-ingress"
"$LIB/apply-manifest.sh" "$NP/kube-system-default-deny.yaml"

# istio-system + topolvm-system — allows + default-deny applied together.
green "==> istio-system: default-deny + xds/webhook/probe allows"
"$LIB/apply-manifest.sh" "$NP/istio-system.yaml"
green "==> topolvm-system: default-deny + kubelet-probe allows"
"$LIB/apply-manifest.sh" "$NP/topolvm-system.yaml"

green "==> system-namespace NetworkPolicies applied (H-4.14)."
