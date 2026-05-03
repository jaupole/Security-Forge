#!/usr/bin/env bash
# Phase 8b.1 — install/upgrade the teleport-cluster Helm release.
#
# Pre-conditions (already true after Phase 8a):
#   - `teleport` ns exists (PSS=restricted)
#   - `tp-secforge-local-tls` Secret rendered by cert-manager
#   - `teleport-oidc-vso` + `teleport-minio-vso` Secrets rendered by VSO
#   - mkcert ClusterIssuer `mkcert-issuer` exists
#
# What this script does:
#   1. Copy the mkcert local CA into the teleport ns as
#      `mkcert-ca-bundle` (key `ca.pem` to match chart default
#      `tls.existingCASecretKeyName`). The chart auto-sets
#      SSL_CERT_FILE to point at this bundle so the proxy can
#      validate its own cert chain (and the OIDC discovery URL
#      to Keycloak, which is also mkcert-signed).
#   2. helm repo add teleport (if not already added) + repo update.
#   3. helm upgrade --install with 03-helm-values.yaml.
#   4. Wait for proxy + auth pods Ready, then apply the OIDC
#      connector + role CRDs.
#
# DANGER (per chart docs): when tls.existingCASecretName is set,
# Teleport ONLY trusts that bundle — the distroless container's
# default Mozilla CA list is dropped. For local edition this is
# fine because every TLS endpoint Teleport talks to (Keycloak
# OIDC discovery, MinIO uses plaintext per audit_sessions_uri
# query string) is mkcert-signed or in-cluster plaintext.

set -euo pipefail

NS=teleport
RELEASE=teleport
CHART_VERSION=18.7.6
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# ─── 1. mkcert CA bundle in teleport ns ────────────────────────────────
green "==> stage mkcert CA bundle into $NS namespace as mkcert-ca-bundle"
MKCERT_CA_SECRET=$(kubectl get clusterissuer mkcert-issuer \
    -o jsonpath='{.spec.ca.secretName}')
CA_CRT=$(kubectl get secret -n cert-manager "$MKCERT_CA_SECRET" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
if [ -z "$CA_CRT" ]; then
    red "could not read $MKCERT_CA_SECRET from cert-manager namespace"
    exit 1
fi
kubectl -n "$NS" create secret generic mkcert-ca-bundle \
    --from-literal=ca.pem="$CA_CRT" \
    --dry-run=client -o yaml | kubectl apply -f -

# ─── 2. Helm repo ──────────────────────────────────────────────────────
green "==> ensure teleport Helm repo"
if helm repo list 2>/dev/null | grep -q '^teleport\s'; then
    yellow "    already present"
else
    helm repo add teleport https://charts.releases.teleport.dev
fi
helm repo update teleport >/dev/null

# ─── 3. Helm upgrade --install ─────────────────────────────────────────
green "==> helm upgrade --install $RELEASE (chart $CHART_VERSION)"
helm upgrade --install "$RELEASE" teleport/teleport-cluster \
    --namespace "$NS" \
    --version "$CHART_VERSION" \
    -f "$HERE/03-helm-values.yaml" \
    --wait --timeout=5m

# ─── 4. Apply Role CRs via operator ────────────────────────────────────
# NOTE: the SSO connector is NOT applied here. Local edition uses the
# TeleportGithubConnector at 06-github-connector.yaml, which has
# placeholders for client_id/org/team that are substituted at apply
# time by apply-github-connector.sh (which also writes the client_secret
# to OpenBao for VSO to render). Run that script after this one
# completes, with credentials from your GitHub OAuth App.
#
# 04-oidc-connector.yaml (Keycloak OIDC) is kept on disk as the
# cloud-edition reference: when Teleport is promoted from CE to
# Enterprise (Enterprise required for OIDC connectors per Teleport's
# feature matrix), kubectl-apply that file in lieu of the GitHub one.
# See ADR-0024 § Amendment 2026-05-03 for the CE→Enterprise cutover
# trigger.

green "==> wait for teleport-operator Deployment Ready"
kubectl rollout status -n "$NS" deploy/teleport-operator --timeout=180s

green "==> apply Role CRs"
kubectl apply -f "$HERE/05-roles.yaml"

green "==> done"
echo
echo "Next step (one-time bootstrap, requires GitHub OAuth App credentials):"
echo "  BAO_TOKEN=<admin> $HERE/apply-github-connector.sh \\"
echo "    <client_id> <client_secret> <github_org> <github_team>"
echo
echo "Verify:"
echo "  kubectl get pods -n $NS"
echo "  kubectl logs -n $NS -l app.kubernetes.io/component=auth --tail=50"
echo "  kubectl logs -n $NS -l app.kubernetes.io/component=proxy --tail=50"
echo "  kubectl get teleportgithubconnector,teleportrolev7 -n $NS"
