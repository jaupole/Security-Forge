# SPIRE ClusterSPIFFEID for ${APP_NAME}.
#
# Issues SVIDs to any pod in this namespace labeled
# `spiffe.io/spire-managed-identity: "true"`.
#
# The SPIFFE ID format encodes namespace + pod-label discriminators so
# that downstream consumers (OpenBao auth-jwt, SpiceDB workload identity)
# can write policies like "spiffe://secforge.platform/ns/${APP_NAME}/sa/*".
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: ${APP_NAME}-default
spec:
  className: spire-spire
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      spiffe.io/spire-managed-identity: "true"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${APP_NAME}
  workloadSelectorTemplates:
    - "k8s:ns:{{ .PodMeta.Namespace }}"
    - "k8s:sa:{{ .PodSpec.ServiceAccountName }}"
