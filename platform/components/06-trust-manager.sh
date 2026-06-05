#!/usr/bin/env bash
# 06 — trust-manager: live distribution of the internal-CA trust bundle.
#
# WHY: app trust bundles used to be hardcoded PEM in per-app
# `08a-openbao-ca-configmap.yaml` ConfigMaps. Whenever an internal CA Secret
# was lost/regenerated (the 2026-06-04 k3s secrets-encryption incident made
# every CA Secret unreadable → cert-manager + istiod minted NEW roots), the
# hardcoded bundles silently went stale and every server-side TLS call to
# Keycloak/OpenBao failed `UNABLE_TO_VERIFY_LEAF_SIGNATURE` until each
# ConfigMap was hand-patched. trust-manager SOURCES the live CA secrets and
# reconciles the target ConfigMaps continuously, so a rotation self-heals.
# See operator-backlog #78.
#
# What this does (idempotent):
#   1. Helm install/upgrade trust-manager into cert-manager ns.
#   2. Reflect the OpenBao root CA (openbao ns) → ConfigMap openbao-ca-source
#      in the trust namespace (cert-manager). trust-manager sources are
#      trust-namespace-scoped, so cross-ns CAs must be reflected in.
#   3. Reflect the CA Keycloak currently serves → ConfigMap
#      keycloak-ca-transitional. TRANSITIONAL: only needed until keycloak's
#      internal cert is re-issued from the current internal-CA ClusterIssuer
#      (Phase 2). Harmless to keep (it's a real, currently-served CA).
#   4. Apply the Bundles (01-bundles.yaml) that write each app's trust
#      ConfigMap (openbao-internal-ca-cert / secforge-internal-ca).
#
# ORDERING: run AFTER the internal-CA ClusterIssuer (cert-manager/internal-ca),
# OpenBao (05), and Keycloak (03) are up — the reflections read those CAs.
# The Bundles' namespaceSelectors self-populate app namespaces as they appear,
# so this may run before the apps (control/member-hub/proposal-forge/wazuh)
# are deployed.
#
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
LIB="$PLATFORM_DIR/lib"
M="$PLATFORM_DIR/manifests"

CHART_VER="${TRUST_MANAGER_CHART_VER:-v0.22.1}"
NS_TRUST=cert-manager

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ─── 1. Install trust-manager ──────────────────────────────────────────────
green ">>> Installing trust-manager ${CHART_VER}"
"$LIB/install-helm.sh" \
  --release trust-manager --namespace "$NS_TRUST" \
  --repo-name jetstack --repo-url https://charts.jetstack.io \
  --chart jetstack/trust-manager --version "$CHART_VER" \
  --values "$PLATFORM_DIR/values/trust-manager.yaml"

# ─── 2. Reflect the OpenBao root CA into the trust namespace ────────────────
green ">>> Reflecting OpenBao root CA → ${NS_TRUST}/openbao-ca-source"
OBCA="$(kubectl get secret -n openbao openbao-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)"
if [ -z "$OBCA" ]; then red "ERROR: openbao-ca secret has no tls.crt"; exit 1; fi
printf '%s' "$OBCA" | kubectl create configmap -n "$NS_TRUST" openbao-ca-source \
  --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

# ─── 3. Reflect the CA Keycloak currently serves (TRANSITIONAL) ────────────
# Drop this block once keycloak-internal-tls is re-issued from the current
# internal-CA ClusterIssuer (Phase 2) and the keycloak-ca-transitional source
# is removed from 01-bundles.yaml.
green ">>> Reflecting Keycloak-served CA → ${NS_TRUST}/keycloak-ca-transitional (transitional)"
KCCA="$(kubectl get secret -n keycloak keycloak-internal-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)"
if [ -z "$KCCA" ]; then red "ERROR: keycloak-internal-tls secret has no ca.crt"; exit 1; fi
printf '%s' "$KCCA" | kubectl create configmap -n "$NS_TRUST" keycloak-ca-transitional \
  --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

# ─── 4. Apply the Bundles ──────────────────────────────────────────────────
green ">>> Applying trust-manager Bundles"
"$LIB/apply-manifest.sh" "$M/trust-manager/01-bundles.yaml"

cat <<EOF

✓ trust-manager wired. App trust ConfigMaps now track the live internal CA.

  Verify:
    kubectl get bundle
    kubectl get cm -n control openbao-internal-ca-cert -o jsonpath='{.metadata.labels}'
    # each app cm should carry 3 certs (internal root + OpenBao + transitional keycloak)

  Phase 2 (collapse the 3-way Internal-CA split — brief IdP blip):
    kubectl delete secret -n keycloak keycloak-internal-tls   # cert-manager re-issues from current ClusterIssuer
    kubectl rollout restart statefulset -n keycloak keycloak
    # then drop the keycloak-ca-transitional source from 01-bundles.yaml + this script
EOF
