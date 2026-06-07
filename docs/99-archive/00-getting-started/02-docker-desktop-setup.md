> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Docker Desktop Kubernetes Configuration

You should already have Docker Desktop installed with Kubernetes enabled (from prerequisites). This doc covers tuning, namespace setup, and the things that bite people specifically about Docker Desktop K8s.

---

## 1. Verify the cluster is the one you think it is

```bash
kubectl config get-contexts
kubectl config current-context  # should say "docker-desktop"
```

If you have multiple contexts (e.g., a leftover EKS context), be careful — running `kubectl apply` against the wrong cluster is a real way to ruin your day.

Recommendation: in your shell prompt, show the current K8s context. Add to `~/.bashrc` or `~/.zshrc`:
```bash
PS1='[k8s:$(kubectl config current-context 2>/dev/null)] \w \$ '
```
Or use `kube-ps1`.

---

## 2. Resource limits for the cluster

Docker Desktop's K8s shares the Docker VM's resources. Settings → Resources → Advanced.

For the SecForge platform:
- **Memory**: 12 GB minimum, 16 GB if you'll run all components + apps simultaneously
- **CPUs**: 4 minimum, 6 if you have them
- **Disk**: 100 GB+ (images add up quickly with the platform's components)

If your machine is 32 GB, allocating 16 GB to Docker Desktop is fine.

After changing, click "Apply & Restart" and wait for K8s to come back up.

---

## 3. Verify cluster capacity

```bash
kubectl describe node docker-desktop | grep -A 5 "Allocatable"
```

Look for:
- `cpu`: should match your allocation roughly
- `memory`: should match your allocation roughly
- `pods`: 110 by default

If pods say "0" or memory looks tiny, the K8s allocation is wrong. Recheck Docker Desktop settings.

---

## 4. Pre-create the SecForge namespaces

We'll create these incrementally as Claude Code goes through phases, but for orientation:

```bash
# Platform namespaces
kubectl create namespace cert-manager
kubectl create namespace ingress-nginx
kubectl create namespace postgres-operator
kubectl create namespace valkey
kubectl create namespace minio
kubectl create namespace spire
kubectl create namespace keycloak
kubectl create namespace spicedb
kubectl create namespace openbao
kubectl create namespace istio-system
kubectl create namespace kyverno

# Observability namespaces
kubectl create namespace observability
kubectl create namespace wazuh

# Application namespaces (created later)
kubectl create namespace app          # Hello World and shared app stuff
kubectl create namespace proposal-forge   # your app 1
kubectl create namespace project-tracker  # your app 2
```

**Don't run these now.** Claude Code will create them in Phase 1 with proper labels and resource quotas. This list is just so you know what's coming.

---

## 5. Increase file descriptor limits (often needed)

Docker on WSL2 sometimes hits file descriptor limits when running many pods. In WSL2 Ubuntu:

```bash
# Check current limits
ulimit -n

# Add to ~/.bashrc to raise on every shell:
echo 'ulimit -n 65536' >> ~/.bashrc
source ~/.bashrc
```

Also verify Docker daemon has high limits. In Docker Desktop → Settings → Docker Engine, ensure the `default-ulimits` section looks like:
```json
{
  "default-ulimits": {
    "nofile": {
      "Hard": 65536,
      "Name": "nofile",
      "Soft": 65536
    }
  }
}
```

---

## 6. Pre-pull common images (optional, makes Phase 1 faster)

If you have time to wait, pre-pulling avoids Phase 1 delays:

```bash
docker pull postgres:16
docker pull valkey/valkey:8
docker pull minio/minio:latest
docker pull quay.io/jetstack/cert-manager-controller:latest
docker pull ghcr.io/spiffe/spire-server:1.10.0
docker pull ghcr.io/spiffe/spire-agent:1.10.0
docker pull quay.io/keycloak/keycloak:26.0
docker pull quay.io/authzed/spicedb:latest
docker pull openbao/openbao:2.0
```

Skip this if you'd rather get going.

---

## 7. About persistent volumes

Docker Desktop's K8s ships with `hostpath` storage class — backed by the Docker VM's disk. This is fine for local development but has quirks:

- **Volumes survive `kubectl delete pvc`** unless the StorageClass has `Delete` reclaim policy. Default is usually `Delete` but check: `kubectl get storageclass`.
- **Volumes don't survive Docker Desktop's "Reset Kubernetes Cluster"** — that wipes everything. Use this option deliberately.
- **Performance is fine for dev** but don't try to benchmark anything.

For our platform, we use PVCs throughout. Local Edition doesn't try to be production-realistic on the storage front; just understand that local-edition Postgres data isn't a real backup of anything.

---

## 8. About networking

Docker Desktop's K8s does some clever stuff to make `localhost` work:
- **Services of type `LoadBalancer`** get a `localhost`-bindable port (you'll see them on `127.0.0.1:<port>`).
- **Ingresses** also bind to `localhost:80` and `localhost:443` once `ingress-nginx` is installed.
- **From inside a pod, `host.docker.internal` resolves to your host machine.** Useful for development but be careful — production K8s does not have this.

We'll use `*.secforge.local` mapped to `127.0.0.1` (next doc: 03-local-dns-and-tls.md). When the browser hits `https://app.secforge.local`, that resolves to localhost, which Docker Desktop's ingress-nginx LoadBalancer service is bound to.

---

## You're done with Docker Desktop setup when:

- [ ] Cluster context is `docker-desktop`
- [ ] Memory and CPU allocations are at least 12 GB / 4 CPU
- [ ] `kubectl get nodes` shows a Ready node
- [ ] You understand that `localhost` and `host.docker.internal` are special
- [ ] File descriptor limits raised
- [ ] (Optional) Common images pre-pulled

Next: **[03-local-dns-and-tls.md](./03-local-dns-and-tls.md)** — set up local DNS and trusted TLS certs.
