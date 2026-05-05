# Cluster Services (Phase 1 Foundation)

Reference for the cluster-wide platform services installed in Phase 1: ingress-nginx, cert-manager, CloudNativePG, Valkey, MinIO, Cosign + Kyverno.

For namespaces and quotas see [`namespaces.md`](./namespaces.md). For Postgres instances see [`postgres-instances.md`](./postgres-instances.md).

---

## Pinned chart versions

| Chart | Version | Repo |
|---|---|---|
| `ingress-nginx/ingress-nginx` | 4.11.3 | https://kubernetes.github.io/ingress-nginx |
| `jetstack/cert-manager` | v1.16.2 | https://charts.jetstack.io |
| `cnpg/cloudnative-pg` | 0.22.1 | https://cloudnative-pg.github.io/charts |
| `bitnami/valkey` | 5.5.1 | https://charts.bitnami.com/bitnami |
| `minio/minio` | 5.4.0 | https://charts.min.io |
| `kyverno/kyverno` | 3.3.4 | https://kyverno.github.io/kyverno/ |

Versions move forward in deliberate bumps via PR; no `latest`.

---

## Apply sequence (top to bottom)

This is the canonical order. Skipping or reordering is asking for trouble — ingress-nginx wants its default-cert Secret before its first start, the test Certificate needs both the ClusterIssuer and the wildcard cert for verification, etc.

```bash
# ============================================================================
# 0. Pre-pull the largest images (saves 5–10 min during apply on slow links)
# ============================================================================
docker pull registry.k8s.io/ingress-nginx/controller:v1.11.3
docker pull quay.io/jetstack/cert-manager-controller:v1.16.2
docker pull ghcr.io/cloudnative-pg/cloudnative-pg:1.24.1
docker pull ghcr.io/cloudnative-pg/postgresql:16.4-bookworm
docker pull bitnami/valkey:8.0.1-debian-12-r0
docker pull quay.io/minio/minio:RELEASE.2024-10-29T16-01-48Z
docker pull ghcr.io/kyverno/kyverno:v1.13.1

# Sanity
kubectl get nodes
kubectl get sc        # confirm a default StorageClass exists

# ============================================================================
# 1.1 — Namespaces, quotas, limit ranges
# ============================================================================
kubectl apply -f infrastructure/namespaces/namespaces.yaml
kubectl get ns -L secforge.platform/component,secforge.platform/edition

# ============================================================================
# 1.2 — ingress-nginx
# ============================================================================
# (a) Wildcard TLS Secret in the ingress namespace (used as default-ssl-cert)
kubectl -n ingress-nginx create secret tls wildcard-secforge-local-tls \
  --cert ~/.local/secforge-certs/secforge.local.pem \
  --key  ~/.local/secforge-certs/secforge.local-key.pem
kubectl -n ingress-nginx label secret wildcard-secforge-local-tls \
  secforge.platform/component=ingress-nginx \
  secforge.platform/edition=local

# (b) Repo + install
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --version 4.11.3 \
  --values infrastructure/ingress-nginx/values.yaml \
  --wait --timeout 5m

# Verify it's serving on localhost:443
curl -kI https://localhost/ | head -5

# ============================================================================
# 1.3 — cert-manager + mkcert ClusterIssuer + test Certificate
# ============================================================================
# (a) mkcert root CA → Secret (the CA private key, kept in cert-manager ns only)
kubectl -n cert-manager create secret tls mkcert-ca-key-pair \
  --cert "$(mkcert -CAROOT)/rootCA.pem" \
  --key  "$(mkcert -CAROOT)/rootCA-key.pem"
kubectl -n cert-manager label secret mkcert-ca-key-pair \
  secforge.platform/component=cert-manager \
  secforge.platform/edition=local

# (b) cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --version v1.16.2 \
  --values infrastructure/cert-manager/values.yaml \
  --wait --timeout 5m

# (c) ClusterIssuer + test Certificate
kubectl apply -f infrastructure/cert-manager/cluster-issuer.yaml
kubectl wait --for=condition=Ready clusterissuer/mkcert-issuer --timeout=60s

kubectl apply -f infrastructure/cert-manager/test-certificate.yaml
kubectl -n app wait --for=condition=Ready certificate/test-secforge-local --timeout=60s

# Verify trust from inside the cluster
kubectl -n app run curl-test --rm -i --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -v --cacert /etc/ssl/cert.pem https://test.secforge.local 2>&1 | head -30
# (Will fail on DNS until 1.8 ingress is up — that's fine; 1.8 closes the loop.)

# ============================================================================
# 1.4 — CloudNativePG operator + Cluster CRs
# ============================================================================
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cnpg/cloudnative-pg \
  --namespace postgres-operator --version 0.22.1 \
  --values infrastructure/cloudnativepg/values.yaml \
  --wait --timeout 5m

# Wait for the webhook
kubectl -n postgres-operator rollout status deploy/cnpg-cloudnative-pg

# Apply each cluster (skip teleport-db.yaml unless deploying Teleport in Phase 8)
kubectl apply -f infrastructure/cloudnativepg/clusters/keycloak-db.yaml
kubectl apply -f infrastructure/cloudnativepg/clusters/spicedb-db.yaml
kubectl apply -f infrastructure/cloudnativepg/clusters/openbao-db.yaml
kubectl apply -f infrastructure/cloudnativepg/clusters/app-db.yaml
# kubectl apply -f infrastructure/cloudnativepg/clusters/teleport-db.yaml   # optional

# Watch them come Healthy (~2 min each on first init)
kubectl get cluster -A -w

# ============================================================================
# 1.5 — Valkey
# ============================================================================
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install valkey bitnami/valkey \
  --namespace valkey --version 2.0.7 \
  --values infrastructure/valkey/values.yaml \
  --wait --timeout 5m

# Smoke test
kubectl -n valkey exec -it valkey-master-0 -- valkey-cli -a "$(kubectl -n valkey get secret valkey -o jsonpath='{.data.valkey-password}' | base64 -d)" PING

# ============================================================================
# 1.6 — MinIO
# ============================================================================
# (a) Pre-create root credentials Secret
kubectl -n minio create secret generic minio-root-credentials \
  --from-literal=rootUser=secforge-admin \
  --from-literal=rootPassword="$(openssl rand -base64 32)"

# (b) Sync the wildcard cert into the minio namespace (used by both Ingresses)
kubectl get secret wildcard-secforge-local-tls -n ingress-nginx -o yaml \
  | sed 's/namespace: ingress-nginx/namespace: minio/' \
  | grep -v '^\s*resourceVersion:\|^\s*uid:\|^\s*creationTimestamp:' \
  | kubectl apply -f -

# (c) Install
helm repo add minio https://charts.min.io
helm repo update
helm install minio minio/minio \
  --namespace minio --version 5.4.0 \
  --values infrastructure/minio/values.yaml \
  --wait --timeout 5m

# Verify console
echo "Open https://minio.secforge.local in your browser"
echo "User:     $(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.rootUser}' | base64 -d)"
echo "Password: $(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)"

# ============================================================================
# 1.7 — Cosign keypair + Kyverno + policies
# ============================================================================
# (a) Generate the Cosign keypair locally (interactive — you'll be prompted
#     for a passphrase). Output: cosign.key (keep secret), cosign.pub (commit).
cd infrastructure/cosign
COSIGN_PASSWORD="$(openssl rand -base64 24)" cosign generate-key-pair
# Save the password — you'll need it to sign images. Store it in OpenBao
# in Phase 5; until then, keep it OUT of git (a password manager is fine).

# (b) Push the private key into a Kyverno-namespace Secret. Don't commit cosign.key.
kubectl -n kyverno create secret generic cosign-signing-key \
  --from-file=cosign.key=cosign.key \
  --from-file=cosign.pub=cosign.pub \
  --from-literal=cosign.password="$COSIGN_PASSWORD"
shred -u cosign.key   # remove the local copy now that it's in a Secret
cd ../..

# (c) Embed the public key into the verify-signatures policy.
#     The committed file has a PLACEHOLDER block; replace it before applying.
PUBKEY=$(cat infrastructure/cosign/cosign.pub | sed 's/^/                      /')
sed -i '/PLACEHOLDER/c\'"$(printf '%s\n' "$PUBKEY")" \
  infrastructure/kyverno/policies/verify-signatures.yaml
# (Spot-check the diff before applying:)
git diff infrastructure/kyverno/policies/verify-signatures.yaml

# (d) Install Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno --version 3.3.4 \
  --values infrastructure/kyverno/values.yaml \
  --wait --timeout 5m

# (e) Apply policies
kubectl apply -f infrastructure/kyverno/policies/pod-security.yaml
kubectl apply -f infrastructure/kyverno/policies/verify-signatures.yaml

# ============================================================================
# 1.8 — Verification
# ============================================================================
# (Phase 1's `test-page` smoke fixture was removed in Phase 7c-1 prep —
#  it had non-mesh ingress-nginx callers that would have been denied at L4
#  under the new app-ns STRICT PeerAuthentication. cert-manager wiring is
#  verified instead by the production certs that pre-date 7c-1, e.g. the
#  helloworld-bff-tls Certificate in `app`.)

# (c) Cluster health
kubectl get pods --all-namespaces
kubectl get certificate -A
kubectl top pods --all-namespaces || echo "metrics-server not installed (Phase 7)"

# (d) Kyverno dry-run: try to apply an unsigned image into `app`.
#     With pod-security in Enforce + verify-signatures in Audit, this should
#     fail on PSS (because the random nginx image runs as root by default)
#     and produce a PolicyReport entry for the missing signature.
kubectl -n app run unsigned-test --image=nginx:latest --dry-run=server -o yaml || true
kubectl -n app get policyreport
```

---

## ingress-nginx

- **Service type**: `LoadBalancer`. Docker Desktop binds the loadbalancer's external IP to `localhost`, exposing :80 and :443 directly on your laptop.
- **Default SSL certificate**: the wildcard cert at `ingress-nginx/wildcard-secforge-local-tls`. Any Ingress without its own `tls:` block falls back to this. Phase 1.6 reuses it for MinIO; Phase 1.8's test Ingress declares its own cert (issued by the ClusterIssuer, the round-trip we want to prove).
- **HTTP/2**: enabled by default. Toggle off in `infrastructure/ingress-nginx/values.yaml` (`controller.config.use-http2: "false"`) only if a specific app misbehaves.
- **HSTS**: 2y preload, includeSubdomains. **This pins the host in your browser.** If you ever serve plain HTTP from `*.secforge.local`, you'll need to clear HSTS state in chrome://net-internals/#hsts.
- **Snippet annotations disabled**. CVE-prone path; we don't need them.
- **Strict path validation enabled**. Rejects ambiguous Ingress paths.
- **GAP — readOnlyRootFilesystem disabled.** The upstream chart 4.11.3 rewrites `/etc/nginx/nginx.conf`, `/etc/ingress-controller/ssl/*`, and `/etc/ingress-controller/telemetry/*` on every reload, with no exhaustive list of write paths in the chart. Three retries with progressively more emptyDir mounts kept turning up new write targets. We accept the gap because the namespace is already PSA `privileged` (it has to be, for host-port binding) and the controller still satisfies: non-root user 101, drop ALL caps + NET_BIND_SERVICE, no privilege escalation, RuntimeDefault seccomp.

---

## cert-manager + mkcert ClusterIssuer

- **`mkcert-ca-key-pair`** (Secret in `cert-manager` ns) holds the root CA's cert + private key. The root key never leaves this Secret. This is the single most sensitive object in the local cluster — its compromise means anyone can forge a cert any browser on this laptop will trust.
- **`mkcert-issuer`** (ClusterIssuer) issues leaf certs by signing CSRs with the root key. Use it for any in-cluster service that wants a cert.
- **Cert renewal**: 90-day cert lifetime, renewed at 15 days remaining. cert-manager handles it automatically.

### Issuing a cert for a new service

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-service-tls
  namespace: my-service
spec:
  secretName: my-service-tls
  dnsNames: [my-service.secforge.local]
  issuerRef: {name: mkcert-issuer, kind: ClusterIssuer}
```

---

## CloudNativePG

See [postgres-instances.md](./postgres-instances.md). Short version: 1 operator pod in `postgres-operator`, 1 Cluster CR per consumer namespace, all auto-managed.

---

## Valkey

- 1 master, 0 replicas, AOF persistence.
- Auth password auto-generated into Secret `valkey/valkey` (key: `valkey-password`).
- **TLS at the Valkey layer is disabled**. Documented gap: Phase 6 lays Istio Ambient mesh + SPIRE-issued mTLS over the wire, which encrypts service-to-service traffic and binds it to SPIFFE identities. Until then, traffic in `valkey` namespace is in cleartext between pods on the same Docker Desktop node — acceptable risk on a single-tenant laptop.

---

## MinIO

- **API**: `https://s3.secforge.local` (S3 wire protocol).
- **Console**: `https://minio.secforge.local`.
- **Root credentials**: Secret `minio/minio-root-credentials`. Generated once at install time. Phase 5 onward, app credentials come from OpenBao's MinIO secrets engine; the root credential is used only for bucket admin and rotated then.
- **Buckets at install**: `audit-logs` (Object Lock + 365d GOVERNANCE retention), `backups`, `wazuh-archive`, `teleport-recordings` (Object Lock + 90d GOVERNANCE retention). All versioned.
- **NetworkPolicy**: chart's policy locks ingress to pods labeled `minio-client=true`. We add a separate NetworkPolicy (`minio-allow-from-ingress-nginx`) that lets ingress-nginx controller pods reach :9000 and :9001, since labelling the controller with a MinIO-specific label is wrong. Phase 5+ services (Keycloak, OpenBao, BFF) will need either the `minio-client=true` label or their own additive NetworkPolicy.
- **Bucket creation**: done by **our own** Job (`infrastructure/minio/bucket-bootstrap-job.yaml`), NOT the upstream chart's `makeBucketJob`. The chart's job exposes only pod-level securityContext, which can't satisfy `restricted` PSA. Our Job runs the same `mc` calls under a fully-locked-down container (drop ALL caps, RO root FS, runAsNonRoot, RuntimeDefault seccomp). Idempotent — rerun whenever values change.

---

## Cosign + Kyverno

- **Cosign**: local key in Secret `kyverno/cosign-signing-key` (private key, public key, passphrase). Public key also committed at `infrastructure/cosign/cosign.pub` for review and CI.
- **Kyverno**: `verify-signatures` ClusterPolicy in **Audit** mode (logs to PolicyReports, doesn't block); `enforce-pod-security-restricted` in **Enforce**.
- **Excluded namespaces** (both policies): `kube-system`, `kube-public`, `kube-node-lease`, `cert-manager`, `kyverno`, `ingress-nginx`, `local-path-storage`. Pod-security additionally excludes `istio-system` and `spire`.
- **Flipping verify-signatures to Enforce**: only after every platform image is signed by our key. See ADR 0004.

### Signing an image with the local Cosign key

```bash
COSIGN_PASSWORD=$(kubectl -n kyverno get secret cosign-signing-key -o jsonpath='{.data.cosign\.password}' | base64 -d)
COSIGN_KEY=k8s://kyverno/cosign-signing-key
COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign sign --key "$COSIGN_KEY" <image>:<tag>
```

---

## Resource budget actually consumed

After Phase 1 finishes, expect roughly:

| Component | RAM steady | CPU steady |
|---|---|---|
| ingress-nginx | ~80 MB | <50m |
| cert-manager (3 pods) | ~150 MB | <50m |
| CNPG operator | ~80 MB | <50m |
| 4× Postgres pods | ~800 MB total | <100m total |
| Valkey | ~80 MB | <20m |
| MinIO | ~200 MB | <50m |
| Kyverno (4 controllers) | ~600 MB | <100m |
| Test page nginx | <20 MB | negligible |
| **Total** | **~2 GB** | **~0.4 CPU** |

That leaves plenty of room for Phases 2–7.

---

## Troubleshooting

**ingress-nginx admission webhook timing out on first apply**: the webhook needs ~30s to come up. If a downstream `kubectl apply` of an Ingress fails immediately after install, retry once.

**cert-manager Certificate stuck `Issuing` forever**: `kubectl describe certificate <name>` and look at the CertificateRequest's events. Most common cause locally: the `mkcert-ca-key-pair` Secret is in the wrong namespace or has the wrong keys (must be `tls.crt` and `tls.key`).

**CloudNativePG cluster stuck `Setting up primary`**: check pod events; usually a PVC binding issue. `kubectl get pvc -A` and confirm the StorageClass is bound.

**Browser still warns "Not secure" at `https://test.secforge.local`**: mkcert root CA isn't trusted by the browser yet. Run `mkcert -install` again on the host (Windows side, not WSL), and restart the browser.

**Kyverno blocking system pods**: it shouldn't — both policies exclude system namespaces. If it does, check `kubectl get clusterpolicy <name> -o yaml` and confirm the `exclude` block matches.
