# App namespace — created from template by bootstrap-app.sh.
#
# Labels:
#   pod-security: restricted enforce (apps must be restricted-compatible)
#   istio.io/dataplane-mode: ambient (auto-joined to mesh)
#   secforge.platform/app: "true" (matched by Kyverno image-sig policy)
#   secforge.platform/namespace-template-version: 1 (for drift detection)
#
# ⚠ AMBIENT + NetworkPolicy (incident 2026-06-03): once this namespace
# is in the Ambient mesh, traffic to/from ANOTHER ambient namespace is
# tunnelled ztunnel→ztunnel over HBONE on TCP/15008 — NOT the app port.
# Every cross-namespace NetworkPolicy between two ambient namespaces MUST
# allow TCP/15008 (HBONE) on BOTH ends (caller egress + callee ingress),
# in addition to the app port. Missing it => ztunnel resets the upstream
# ("Connection reset by peer"), not a clean timeout. Intra-namespace and
# ambient↔non-ambient paths are unaffected (plain L4 on the app port).
# See docs/01-architecture/07-service-mesh.md "Ambient + NetworkPolicy".
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NAME}
  labels:
    secforge.platform/app: "true"
    secforge.platform/namespace-template-version: "1"
    secforge.platform/component: app
    secforge.platform/managed-by: bootstrap-app.sh
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    istio.io/dataplane-mode: ambient
