#!/usr/bin/env bash
# Phase 6b-2 commit 4 — security-events-collector build.
#
# Mirrors apps/helloworld-bff/build.sh but skips the mkcert root-CA
# bundling step (the collector doesn't connect to in-cluster TLS
# endpoints whose certs need the local CA — JWKS fetches go through
# the system trust store via ingress-nginx, whose cert is mkcert-issued
# but the collector validates against the system bundle which is
# fine for ambient-mesh service-to-service connections).
#
# Steps:
#   1. docker build with the deterministic Dockerfile.
#   2. SBOM via Syft.
#   3. Trivy + Grype scan; fail on HIGH+CRITICAL vuln OR ANY secret
#      finding (ADR-0013 § Layer 3).
#
# Cosign signing is DEFERRED — same posture as authzen-facade and
# helloworld-bff. Future supply-chain phase wires it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

IMAGE="${IMAGE:-local/security-events-collector:0.1.0}"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

green "==> 1/3 docker build $IMAGE"
docker build -f "$HERE/Dockerfile" -t "$IMAGE" "$HERE/.."

green "==> 2/3 SBOM (Syft → SPDX)"
mkdir -p "$HERE/sbom"
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HERE/sbom:/out" \
    anchore/syft:v1.18.1 "$IMAGE" \
    -o spdx-json=/out/security-events-collector.spdx.json \
    -o table=/out/security-events-collector.sbom.txt
green "    wrote sbom/security-events-collector.spdx.json"

green "==> 3/3 scan (Trivy + Grype)"
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
    anchore/grype:v0.86.1 sbom:/sbom/security-events-collector.spdx.json \
        --fail-on critical \
        --quiet || GRYPE_FAIL=$?

if [ $TRIVY_FAIL -ne 0 ] || [ $GRYPE_FAIL -ne 0 ]; then
    red "scanner failures: trivy=$TRIVY_FAIL grype=$GRYPE_FAIL"
    exit 1
fi

green ""
green "Image $IMAGE built clean."
yellow "Cosign signing DEFERRED (matches platform posture). Image is loaded"
yellow "into Docker Desktop's K8s daemon and ready to deploy."
