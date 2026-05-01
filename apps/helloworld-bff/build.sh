#!/usr/bin/env bash
# Phase 6.7 — build / sbom / scan / (sign).
#
# Run from anywhere; this script paths-resolve to its own directory.
#
# Steps:
#   1. Stage mkcert root CA into the build context (developer-local;
#      not committed).
#   2. docker build with the deterministic Dockerfile (committed go.sum,
#      go mod download — no go mod tidy at build time).
#   3. Generate SPDX SBOM via dockerized Syft, write to ./sbom/.
#   4. Scan with dockerized Trivy and Grype; fail on CRITICAL.
#   5. Cosign signing is DEFERRED, matching the existing project posture
#      (Kyverno is in Audit mode per ADR-0004, authzen-facade is also
#      unsigned, supply-chain pipeline lands in a future phase). Note
#      printed at the end.
#
# Local-edition convenience: Docker Desktop's K8s shares the host docker
# daemon, so a tagged image is immediately available to the cluster — no
# `docker push` needed.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

IMAGE="${IMAGE:-helloworld-bff:0.1.0}"

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
# Build context is apps/ (parent dir) so the Dockerfile can COPY both
# helloworld-bff/ and the sibling lib/ via the local go.mod replace.
# Fix-after-07 §A.5 introduced this multi-module dep.
docker build -f "$HERE/Dockerfile" -t "$IMAGE" "$HERE/.."

green "==> 3/4 SBOM (Syft → SPDX)"
mkdir -p "$HERE/sbom"
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HERE/sbom:/out" \
    anchore/syft:v1.18.1 "$IMAGE" \
    -o spdx-json=/out/helloworld-bff.spdx.json \
    -o table=/out/helloworld-bff.sbom.txt
green "    wrote sbom/helloworld-bff.spdx.json + sbom/helloworld-bff.sbom.txt"

green "==> 4/4 scan (Trivy + Grype)"
TRIVY_FAIL=0
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.58.0 image \
        --severity CRITICAL \
        --ignore-unfixed \
        --exit-code 1 \
        --quiet \
        "$IMAGE" || TRIVY_FAIL=$?

GRYPE_FAIL=0
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HERE/sbom:/sbom" \
    anchore/grype:v0.86.1 sbom:/sbom/helloworld-bff.spdx.json \
        --fail-on critical \
        --quiet || GRYPE_FAIL=$?

if [ $TRIVY_FAIL -ne 0 ] || [ $GRYPE_FAIL -ne 0 ]; then
    red "scanner failures: trivy=$TRIVY_FAIL grype=$GRYPE_FAIL"
    exit 1
fi

green ""
green "Image $IMAGE built clean."
yellow "Cosign signing DEFERRED (matches existing project posture):"
yellow "  - Kyverno verify-image-signatures runs in Audit mode (ADR-0004)"
yellow "  - authzen-facade also ships unsigned (PLAN.md Phase 4 deviations)"
yellow "  - supply-chain pipeline (Cosign + key custody) is a future phase"
yellow "Image is loaded into Docker Desktop's K8s daemon and ready to deploy."
