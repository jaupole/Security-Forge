#!/usr/bin/env bash
# Build, deploy, and smoke-test the AuthZEN façade.
#
# PREREQUISITE — Docker Desktop containerd image store.
# `docker build` writes to docker daemon's image store, which on
# Docker Desktop is SEPARATE from the containerd store K8s pulls
# from. To make `imagePullPolicy: Never` work:
#   Settings → General → "Use containerd for pulling and storing
#   images" → enable, restart Docker Desktop.
# Without this toggle, the Deployment goes into ErrImageNeverPull
# and apply.sh's wait-for-rollout step times out.
#
#   1. docker build the image (multi-stage; no local Go needed).
#   2. Mirror the SpiceDB pre-shared key + CA cert from
#      spicedb/spicedb-config and spicedb/spicedb-grpc-tls into a Secret
#      in the `app` ns (cross-ns Secret mount isn't a thing in K8s).
#      Phase 5 (OpenBao) replaces this mirror with a SPIFFE-bound
#      dynamic credential fetch.
#   3. Apply the deploy manifests.
#   4. Wait for the Deployment to be Ready.
#   5. Run a smoke test against /readyz and POST /access/v1/evaluation.

set -euo pipefail
NS=app
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD_DIR="$ROOT/authzen-facade"
APPS_DIR="$ROOT"   # apps/ — wider context after Fix-after-07 §A.6 (lib sibling needed)
IMAGE_TAG="local/authzen-facade:0.1.0"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# 1. Build.
green "==> docker build $IMAGE_TAG"
# Build context is apps/ so the Dockerfile can COPY both authzen-facade/
# and the sibling lib/ via the local go.mod replace.
docker build -f "$BUILD_DIR/Dockerfile" -t "$IMAGE_TAG" "$APPS_DIR" >/dev/null

# 2. Mirror SpiceDB creds into the app namespace.
green "==> mirroring SpiceDB pre-shared key + CA into app/authzen-facade-spicedb-creds"
PSK=$(kubectl get secret -n spicedb spicedb-config        -o jsonpath='{.data.preshared_key}' | base64 -d)
CA=$( kubectl get secret -n spicedb spicedb-grpc-tls      -o jsonpath='{.data.ca\.crt}'      | base64 -d)

kubectl -n "$NS" delete secret authzen-facade-spicedb-creds --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic authzen-facade-spicedb-creds \
    --from-literal=preshared_key="$PSK" \
    --from-file=ca.crt=/dev/stdin <<<"$CA" >/dev/null
kubectl -n "$NS" label secret authzen-facade-spicedb-creds \
    app.kubernetes.io/name=authzen-facade \
    secforge.platform/component=authzen-facade \
    secforge.platform/source=mirrored-from-spicedb-ns \
    --overwrite >/dev/null
unset PSK CA

# 3. Apply manifests.
green "==> applying ServiceAccount, Deployment, Service, NetworkPolicies"
kubectl apply -f "$HERE/01-serviceaccount.yaml"
kubectl apply -f "$HERE/04-networkpolicies.yaml"
kubectl apply -f "$HERE/02-deployment.yaml"
kubectl apply -f "$HERE/03-service.yaml"

# 4. Wait for rollout.
green "==> waiting for Deployment Ready"
kubectl -n "$NS" rollout status deployment/authzen-facade --timeout=180s

# 5. Smoke test from inside the cluster (zed-check-runner pod is handy).
green "==> smoke test"
kubectl run -n "$NS" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:latest \
    --labels=role=authzen-smoketest \
    --overrides='{
      "spec": {
        "securityContext": {"runAsNonRoot": true, "runAsUser": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{
          "name": "curl",
          "image": "curlimages/curl:latest",
          "stdin": true, "stdinOnce": true,
          "command": ["sh", "-c"],
          "args": ["curl -sS -o /dev/null -w \"readyz=%{http_code}\\n\" http://authzen-facade.app.svc.cluster.local:8080/readyz; curl -sS -X POST -H content-type:application/json --data \"{\\\"subject\\\":{\\\"type\\\":\\\"user\\\",\\\"id\\\":\\\"jason\\\"},\\\"action\\\":{\\\"name\\\":\\\"view\\\"},\\\"resource\\\":{\\\"type\\\":\\\"document\\\",\\\"id\\\":\\\"welcome\\\"}}\" http://authzen-facade.app.svc.cluster.local:8080/access/v1/evaluation"],
          "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "capabilities": {"drop": ["ALL"]}, "seccompProfile": {"type": "RuntimeDefault"}}
        }]
      }
    }' \
    authzen-smoketest

green ""
green "AuthZEN façade is live at http://authzen-facade.app.svc.cluster.local:8080"
green "Run more checks via:"
green "  kubectl run -n app --rm -i --restart=Never --image=curlimages/curl:latest tmp-curl -- ..."
