# VSO consumer skeleton for ${APP_NAME}.
#
# Creates the SA + VaultAuth that authenticates this namespace's
# workloads against OpenBao via the K8s auth method.
#
# The app's own Helm chart adds VaultStaticSecret resources that point
# at specific KV paths and render into K8s Secrets. The K8s auth role
# `${APP_NAME}-vso` (created out-of-band by bootstrap-app.sh) governs
# which OpenBao paths this namespace can read.

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}-vso
  namespace: ${APP_NAME}
  labels:
    secforge.platform/role: vso-consumer-binding
automountServiceAccountToken: true

---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: default
  namespace: ${APP_NAME}
spec:
  vaultConnectionRef: vault-secrets-operator/openbao
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: ${APP_NAME}-vso
    serviceAccount: ${APP_NAME}-vso
    audiences:
      - https://kubernetes.default.svc.cluster.local
