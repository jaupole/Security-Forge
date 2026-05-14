# ResourceQuota + LimitRange for ${APP_NAME}.
#
# ResourceQuota caps the SUM of all pods' requests/limits in this namespace.
# LimitRange sets DEFAULT requests/limits for any pod that doesn't declare
# them (so Kyverno's require-resource-limits never has to fail-the-deploy
# on a missing limit; the LimitRange fills it in).

---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${APP_NAME}-quota
  namespace: ${APP_NAME}
spec:
  hard:
    requests.cpu: "${APP_CPU_REQ_QUOTA}"
    requests.memory: "${APP_MEM_REQ_QUOTA}"
    limits.cpu: "${APP_CPU_LIMIT_QUOTA}"
    limits.memory: "${APP_MEM_LIMIT_QUOTA}"
    persistentvolumeclaims: "10"
    services.loadbalancers: "0"   # apps don't get LB Services; ingress-nginx fronts them

---
apiVersion: v1
kind: LimitRange
metadata:
  name: ${APP_NAME}-limits
  namespace: ${APP_NAME}
spec:
  limits:
    - type: Container
      default:
        cpu: "${APP_CPU_LIMIT}"
        memory: "${APP_MEM_LIMIT}"
      defaultRequest:
        cpu: "${APP_CPU_REQ}"
        memory: "${APP_MEM_REQ}"
      max:
        cpu: "${APP_CPU_LIMIT}"
        memory: "${APP_MEM_LIMIT}"
