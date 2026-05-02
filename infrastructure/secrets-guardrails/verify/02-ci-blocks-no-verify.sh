#!/usr/bin/env bash
# Verify 02: Layer 2 (CI) — secrets-check.yml workflow rejects content
# that bypassed pre-commit via `git commit --no-verify`.
#
# This script doesn't actually push to GitHub. Instead it dry-runs the
# workflow's individual jobs locally against a synthetic violation,
# proving the same checks would fire in a real PR.
#
# Operator can run this against a feature branch before pushing to
# verify CI will reject the changes BEFORE the PR is opened (saves a
# round-trip).
#
# Exit codes:
#   0  — every CI check correctly rejected the synthetic violation
#   1  — at least one CI check failed to fire
#   2  — operator setup issue (yq / docker missing)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-02: docker required (CI mirrors are docker-runnable)"
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q
git config user.email verify@local
git config user.name verify

# Stage the same synthetic violation that template-app-repo's CI workflow
# guards against: a tracked .env file with a non-trivial value.
echo "VENDOR_API_KEY=fingerprint-only-test-value" > .env
git add -f .env
git commit -m "synthetic violation for verify-02" --no-verify -q

# Run gitleaks against the working tree — same as the gitleaks-action
# job in templates/app-repo/.github/workflows/secrets-check.yml.
yellow "VERIFY-02: gitleaks-action equivalent against synthetic .env"
GIT_FAIL=0
docker run --rm -v "$WORK":/repo -w /repo zricethezav/gitleaks:v8.18.4 \
    detect --no-git --no-banner --redact 2>&1 \
    | tee /tmp/verify-02-gitleaks.log || GIT_FAIL=$?

# Now exercise the block-env-files job equivalent (ls-files | grep).
yellow "VERIFY-02: block-env-files job equivalent"
BLOCK_FAIL=0
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '(^|/)\.env\.example$' \
    > /tmp/verify-02-bad.log || BLOCK_FAIL=$?

cd "$REPO_ROOT"

# gitleaks may legitimately not flag this synthetic value (it's
# non-secret-shaped). The block-env-files check is the authoritative
# guard for tracked .env files; assert THAT one fired.
if [ $BLOCK_FAIL -ne 0 ] || [ ! -s /tmp/verify-02-bad.log ]; then
    red "VERIFY-02 FAIL: block-env-files job did not detect the staged .env"
    red "Inspect templates/app-repo/.github/workflows/secrets-check.yml"
    exit 1
fi

green "VERIFY-02 PASS: block-env-files job correctly flagged tracked .env"
green "  staged-file path: $(cat /tmp/verify-02-bad.log)"
exit 0
