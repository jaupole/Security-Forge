# App namespace — created from template by bootstrap-app.sh.
#
# Labels:
#   pod-security: restricted enforce (apps must be restricted-compatible)
#   istio.io/dataplane-mode: ambient (auto-joined to mesh)
#   secforge.platform/app: "true" (matched by Kyverno image-sig policy)
#   secforge.platform/namespace-template-version: 1 (for drift detection)
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
