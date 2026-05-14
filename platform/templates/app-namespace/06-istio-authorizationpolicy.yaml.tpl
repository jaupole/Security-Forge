# Istio AuthorizationPolicy — default-DENY for ${APP_NAME}.
#
# By default, no traffic is allowed into pods in this namespace at the
# mesh layer. The app's own Helm chart adds per-route ALLOW rules
# (e.g., "allow ingress-nginx to call /healthz at port 8080").
#
# Combined with the L4 NetworkPolicies (default-deny + allow-lists) and
# the L7 Istio policy here, the app starts in a "secure default" state.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny-all
  namespace: ${APP_NAME}
spec:
  {}                  # empty spec = deny all traffic to all workloads
