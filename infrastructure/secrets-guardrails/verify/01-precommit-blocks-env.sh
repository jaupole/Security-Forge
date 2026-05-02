#!/usr/bin/env bash
# Verify 01: Layer 1 (developer machine) — pre-commit `block-env-files`
# rejects a staged .env file. ADR-0013 § Multi-layer prevention guardrails.
#
# Operator-runnable. Idempotent (cleans up its own staging artifacts).
# Assumes the working tree starts clean; refuses to run otherwise so an
# unrelated mid-edit isn't masked by the test artifact.
#
# Exit codes:
#   0  — pre-commit correctly rejected the .env staging
#   1  — guardrail failed (.env was allowed through OR pre-commit absent)
#   2  — operator setup issue (working tree dirty, hook not installed)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Sanity — refuse to run on a dirty tree so the cleanup step can't
# accidentally restore an unrelated WIP edit.
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    red "VERIFY-01: working tree dirty; commit or stash before running."
    exit 2
fi

if ! command -v pre-commit >/dev/null 2>&1; then
    red "VERIFY-01: pre-commit not installed (apt install pre-commit OR pipx install pre-commit)"
    exit 2
fi

# Ensure pre-commit hooks are installed.
if [ ! -f .git/hooks/pre-commit ]; then
    red "VERIFY-01: .git/hooks/pre-commit missing — run \`pre-commit install\`"
    exit 2
fi

# Stage a .env file under templates/app-repo/ where the per-app
# .pre-commit-config.yaml's local hook is expected to fire. Use the
# template's repo-root .pre-commit-config.yaml as the gate (commit 3
# wired gitleaks + check-yaml etc.; for the env-file block we hold
# the per-app template responsible — verified at template-instance time).
TEST_FILE=".env.verify-01-tmp"
trap 'rm -f "$TEST_FILE"; git reset HEAD -- "$TEST_FILE" 2>/dev/null || true' EXIT
echo "FAKE_TEST=value" > "$TEST_FILE"

git add -f "$TEST_FILE" 2>/dev/null

# pre-commit run scoped to the staged file. The repo-level config does
# NOT include the block-env-files local hook — that's per-app under
# templates/app-repo/. The repo-level config does include
# detect-private-key + gitleaks + check-yaml, none of which fire on
# this synthetic non-secret content. To exercise the per-template
# hook, we emit the assertion against a known-failing entry point: the
# template's pre-commit-config invoked manually.
yellow "VERIFY-01: invoking templates/app-repo/.pre-commit-config.yaml against the staged .env"
RESULT=0
pre-commit run \
    --config templates/app-repo/.pre-commit-config.yaml \
    --files "$TEST_FILE" 2>&1 | tee /tmp/verify-01.log || RESULT=$?

if [ $RESULT -eq 0 ]; then
    red "VERIFY-01 FAIL: pre-commit allowed .env through (RESULT=0)."
    red "Layer 1 guardrail is broken — fix templates/app-repo/.pre-commit-config.yaml."
    exit 1
fi

if grep -q "block-env-files" /tmp/verify-01.log; then
    green "VERIFY-01 PASS: block-env-files fired and rejected $TEST_FILE"
    exit 0
fi

red "VERIFY-01 FAIL: pre-commit failed but block-env-files hook did not fire."
red "Inspect /tmp/verify-01.log for the actual rejection reason."
exit 1
