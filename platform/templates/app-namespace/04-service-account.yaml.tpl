# Default ServiceAccount for ${APP_NAME}.
#
# automountServiceAccountToken: false — the SA token is only mounted when
# a workload explicitly references it via spec.serviceAccountName +
# spec.automountServiceAccountToken=true. This avoids accidentally
# leaking credentials into pods that don't need them.
#
# The app's own Helm chart can create additional SAs with token mounting
# enabled if it specifically needs them (e.g., a CRD controller).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-default
  namespace: ${APP_NAME}
  labels:
    secforge.platform/role: default-app-sa
automountServiceAccountToken: false
