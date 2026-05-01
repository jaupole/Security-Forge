---
description: Verify all platform components are healthy locally
---

# Platform Health Check (Local)

Run a thorough health check of every deployed platform component on the local Docker Desktop K8s cluster. For each, report ✅ healthy / ⚠️ degraded / ❌ down.

## Checks to run (in order)

### 1. Docker Desktop & Kubernetes
```bash
docker version
docker stats --no-stream
kubectl config current-context  # should be docker-desktop
kubectl get nodes -o wide
kubectl get pods --all-namespaces | grep -v "Running\|Completed"
```

### 2. Resource pressure
```bash
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=memory | head -20
```
Verify: docker-desktop node has enough RAM (memory pressure < 80%). If pressure is high, recommend the user shut down components they're not currently working on.

### 3. SPIRE
```bash
kubectl exec -n spire deployment/spire-server -- /opt/spire/bin/spire-server agent list
kubectl exec -n spire deployment/spire-server -- /opt/spire/bin/spire-server entry show -limit 5
```

### 4. Keycloak
```bash
kubectl get keycloak -A
curl -sf https://auth.secforge.local/health/ready
```

### 5. SpiceDB
```bash
kubectl get pods -n spicedb
grpcurl -insecure -authority spicedb.secforge.local spicedb.secforge.local:443 grpc.health.v1.Health/Check
```

### 6. OpenBao
```bash
kubectl exec -n openbao openbao-0 -- bao status
```

### 7. Istio
```bash
kubectl get pods -n istio-system
istioctl analyze --all-namespaces
```

### 8. Wazuh (if deployed)
```bash
kubectl get pods -n wazuh
```

### 9. Hello World app (if Phase 9 complete)
```bash
curl -sf https://app.secforge.local/healthz
```

## Output format

Markdown table with each check, then a summary:
- "Platform is healthy. All components operational."
- OR "Platform has N issues requiring attention: ..."

If memory pressure is the issue rather than a real failure, say so explicitly so the user knows it's a resource problem not a config problem.
