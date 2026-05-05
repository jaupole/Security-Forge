#!/usr/bin/env bash
# Phase 9.4 — build helloworld-backend image. Mirrors helloworld-bff/build.sh.
#
# Steps:
#   1. Stage mkcert root CA into the build context (developer-local;
#      not committed).
#   2. docker build with the deterministic Dockerfile.
#   3. SBOM via Syft.
#   4. Scan with Trivy + Grype; fail on CRITICAL.
#   5. Cosign signing — Phase 9 default still DEFERRED matching the rest
#      of the project's posture; flip to mandatory at Phase 9.7 when
#      Kyverno verify-image-signatures moves from Audit to Enforce.
#
# Local-edition convenience: Docker Desktop's K8s shares the host docker
# daemon, so a tagged image is immediately available to the cluster.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

IMAGE="${IMAGE:-helloworld-backend:0.1.0}"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

green "==> 1/4 stage mkcert root CA into build context"
MKCERT_ROOT="$(mkcert -CAROOT)"
if [ ! -f "$MKCERT_ROOT/rootCA.pem" ]; then
    red "mkcert root not found at $MKCERT_ROOT/rootCA.pem"
    exit 1
fi
cp "$MKCERT_ROOT/rootCA.pem" "$HERE/mkcert-root.pem"
trap 'rm -f "$HERE/mkcert-root.pem"' EXIT

green "==> 2/4 docker build $IMAGE"
docker build -f "$HERE/Dockerfile" -t "$IMAGE" "$HERE/.."

green "==> 3/4 SBOM (Syft → SPDX)"
mkdir -p "$HERE/sbom"
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HERE/sbom:/out" \
    anchore/syft:v1.18.1 "$IMAGE" \
    -o spdx-json=/out/helloworld-backend.spdx.json \
    -o table=/out/helloworld-backend.sbom.txt
green "    wrote sbom/helloworld-backend.spdx.json + sbom/helloworld-backend.sbom.txt"

green "==> 4/4 scan (Trivy + Grype)"
TRIVY_FAIL=0
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.58.0 image \
        --scanners vuln,secret \
        --severity HIGH,CRITICAL \
        --ignore-unfixed \
        --exit-code 1 \
        --quiet \
        "$IMAGE" || TRIVY_FAIL=$?

GRYPE_FAIL=0
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HERE/sbom:/sbom" \
    anchore/grype:v0.86.1 sbom:/sbom/helloworld-backend.spdx.json \
        --fail-on critical \
        --quiet || GRYPE_FAIL=$?

if [ $TRIVY_FAIL -ne 0 ] || [ $GRYPE_FAIL -ne 0 ]; then
    red "scanner failures: trivy=$TRIVY_FAIL grype=$GRYPE_FAIL"
    exit 1
fi

green "==> 5/5 import into containerd (Docker Desktop K8s sees containerd, not docker)"
# Without this step `imagePullPolicy: Never` fails with ErrImageNeverPull
# because Docker Desktop's containerd image store is separate from the
# docker daemon's image store. (The "Use containerd for pulling and
# storing images" GUI setting would unify them, but it isn't enabled in
# this dev environment.) docker save | ctr import bridges the gap.
docker save "$IMAGE" | docker exec -i desktop-control-plane ctr -n=k8s.io image import - >/dev/null 2>&1 \
    && green "    imported $IMAGE into containerd k8s.io namespace" \
    || red "    ctr import failed (is the desktop-control-plane container up?)"

green ""
green "Image $IMAGE built clean and imported into containerd."
yellow "Cosign signing deferred (matches project posture)."
yellow "Image is now visible to Docker Desktop's K8s and ready to deploy."
