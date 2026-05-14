# Egress baseline — default-deny-egress + essentials (DNS + K8s API).
#
# Phase C #4 hardening (Layer A). Applied per-namespace via
# platform/lib/apply-egress-baseline.sh <namespace>.
#
# This template is identical across ALL namespaces; the ${NS} placeholder
# is the only difference. Per-namespace SPECIFIC egress allows (e.g.,
# cert-manager → public 443, velero → minio) live in separate
# `0X-egress-<purpose>.yaml` files in each namespace's manifest dir.
#
# Why two policies and not one:
#   - default-deny: empty rules, kicks every pod into "egress restricted"
#     mode (NetworkPolicy semantics: any matching NP enables enforcement).
#   - essentials: layered allows for DNS to coredns + K8s apiserver.
#     Splitting makes it easy to audit "is the baseline applied" vs
#     "is the workload-specific allow set complete".
#
# K8s API endpoint: on k3s the kubernetes Service ClusterIP is
# 10.43.0.1:443, but the actual TLS endpoint is the host's :6443. NPs
# evaluate the post-DNAT destination, so we need both ipBlocks.

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: ${NS}
  labels:
    secforge.platform/component: egress-baseline
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-essentials
  namespace: ${NS}
  labels:
    secforge.platform/component: egress-baseline
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - to:
        - ipBlock:
            cidr: 10.43.0.1/32
      ports:
        - port: 443
          protocol: TCP
    - to:
        - ipBlock:
            cidr: 65.21.25.40/32
      ports:
        - port: 6443
          protocol: TCP
