---
description: Reset the local cluster to a clean state (DESTRUCTIVE)
---

# Reset Local Cluster

Tear down everything in the SecForge platform on the local cluster so the user can start fresh. This is local-only — never use this command in any non-local context.

## Confirm with the user first

Before doing anything, show what will be destroyed and ask explicit confirmation:

```
This will permanently delete:
- All SecForge namespaces (platform components and apps)
- All persistent volumes (Postgres data, MinIO data, Wazuh indices)
- All cert-manager certificates
- All Helm releases

This will NOT delete:
- Docker Desktop's Kubernetes itself
- Your project files in this repository
- The mkcert local CA

Are you sure? (Type "reset" to confirm)
```

Wait for the user to type exactly "reset". Anything else, abort.

## Reset procedure

```bash
# Delete platform namespaces
for ns in app helloworld keycloak spicedb openbao spire istio-system cert-manager kyverno wazuh observability teleport ingress-nginx postgres-operator valkey minio; do
  kubectl delete namespace "$ns" --ignore-not-found=true --wait=false
done

# Wait for actual deletion (can take a minute as PVCs are reclaimed)
kubectl get namespaces

# Verify Helm has nothing left
helm ls --all-namespaces

# Clean up any lingering PVs
kubectl get pv
# If any PVs are stuck Released, delete them:
# kubectl delete pv <name>
```

## After reset

Tell the user:
- Cluster is clean
- They can re-run from Phase 1
- If they want to truly nuke Docker Desktop K8s, the option is in Docker Desktop → Settings → Reset Kubernetes Cluster

Do NOT run that automatically — that's a Docker Desktop-only setting.
