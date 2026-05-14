# Default-deny + minimal-allow NetworkPolicies for ${APP_NAME}.
#
# Egress allow list (rendered from APP_TRUSTED_NAMESPACES):
#   - kube-system DNS
#   - K8s API server (10.43.0.1:443 + host:6443) — for service-account
#     token reviews and any controller-runtime / client-go usage
#   - openbao.openbao.svc:8200 (so the app's pods can reach OpenBao if
#     they bypass VSO and call directly via SPIFFE-JWT auth)
#   - observability (otel-collector for traces)
#   - ${APP_TRUSTED_NAMESPACES} per-app allow list

# ─── default-deny ingress ────────────────────────────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Ingress]

# ─── default-deny egress ─────────────────────────────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]

# ─── allow ingress from ingress-nginx ────────────────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx

# ─── allow ingress from observability (Prometheus scrape) ────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability

# ─── allow egress: DNS ───────────────────────────────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

# ─── allow egress: kube-apiserver (k3s ClusterIP + host endpoint) ────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-kube-apiserver
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 10.43.0.1/32
        - ipBlock:
            cidr: 65.21.25.40/32
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443

# ─── allow egress: OpenBao ───────────────────────────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-openbao
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openbao
          podSelector:
            matchLabels:
              app.kubernetes.io/name: openbao
      ports:
        - protocol: TCP
          port: 8200

# ─── allow egress: observability (OTel traces) ───────────────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-otel-collector
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
          podSelector:
            matchLabels:
              app.kubernetes.io/name: opentelemetry-collector
      ports:
        - protocol: TCP
          port: 4317
        - protocol: TCP
          port: 4318

# ─── allow egress: SPIRE workload API socket (in-cluster) ────────────
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-spire
  namespace: ${APP_NAME}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: spire
      ports:
        - protocol: TCP
          port: 8081
        - protocol: TCP
          port: 8443
