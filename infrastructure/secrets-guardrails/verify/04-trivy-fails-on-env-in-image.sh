#!/usr/bin/env bash
# Verify 04: Layer 3 (build-time) — Trivy `--scanners vuln,secret` fails
# the build when a .env file slips into the image layer cache.
#
# Builds a synthetic image with a .env in the build context, runs the
# same Trivy invocation as apps/helloworld-bff/build.sh (commit 3 flip),
# and asserts a non-zero exit code.
#
# Exit codes:
#   0  — Trivy correctly failed the synthetic image
#   1  — Trivy passed the synthetic image (guardrail broken)
#   2  — operator setup issue (docker missing)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-04: docker required"
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; docker rmi -f verify-04-bad:tmp >/dev/null 2>&1 || true' EXIT
cd "$WORK"

# A real-looking-but-fake credential (split-and-concat per CLAUDE.md
# "no secrets in code"). Trivy's secret scanner pattern-matches against
# Stripe-shaped sk_live_ prefixes; the value below is structurally the
# right shape but a hard-coded all-zeros suffix.
cat > .env <<EOF
STRIPE_API_KEY=sk_live_$(printf '0%.0s' {1..32})
EOF

cat > Dockerfile <<'EOF'
FROM alpine:3.20
COPY .env /etc/.env
CMD ["true"]
EOF

yellow "VERIFY-04: building synthetic image with .env in context"
docker build --quiet -t verify-04-bad:tmp . > /dev/null

yellow "VERIFY-04: Trivy --scanners vuln,secret (mirrors helloworld-bff/build.sh)"
TRIVY_FAIL=0
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.58.0 image \
        --scanners vuln,secret \
        --severity HIGH,CRITICAL \
        --ignore-unfixed \
        --exit-code 1 \
        --quiet \
        verify-04-bad:tmp 2>&1 \
    | tee /tmp/verify-04.log || TRIVY_FAIL=$?

if [ $TRIVY_FAIL -ne 0 ]; then
    green "VERIFY-04 PASS: Trivy failed (exit=$TRIVY_FAIL) on synthetic .env-bearing image"
    exit 0
fi
red "VERIFY-04 FAIL: Trivy passed an image that contained a Stripe-shaped key"
red "Check apps/*/build.sh for --scanners vuln,secret; commit 3 flipped this."
exit 1
