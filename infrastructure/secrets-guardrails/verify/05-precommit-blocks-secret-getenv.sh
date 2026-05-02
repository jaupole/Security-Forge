#!/usr/bin/env bash
# Verify 05: Layer 1 (developer machine) — pre-commit
# `block-secret-shaped-vars` rejects a Go source file containing
# `os.Getenv("OPENAI_KEY")`. ADR-0013 § Multi-layer prevention guardrails.
#
# Operator-runnable. Mirrors verify-01's structure but stages a Go file
# instead of a .env file.
#
# Exit codes:
#   0  — pre-commit correctly rejected the staged Go source
#   1  — guardrail failed (Go source allowed through)
#   2  — operator setup issue

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    red "VERIFY-05: working tree dirty; commit or stash first."
    exit 2
fi

if ! command -v pre-commit >/dev/null 2>&1; then
    red "VERIFY-05: pre-commit not installed"
    exit 2
fi

# A Go source file with a secret-shaped env-var read. Sigil pattern
# matches the same regex Kyverno uses (commit 4) and the
# block-secret-shaped-vars hook (commit 3).
TEST_FILE="verify-05-tmp.go"
trap 'rm -f "$TEST_FILE"; git reset HEAD -- "$TEST_FILE" 2>/dev/null || true' EXIT
cat > "$TEST_FILE" <<'EOF'
package main

import "os"

func main() {
    _ = os.Getenv("OPENAI_KEY")
}
EOF

git add -f "$TEST_FILE" 2>/dev/null

yellow "VERIFY-05: invoking templates/app-repo/.pre-commit-config.yaml against the Go file"
RESULT=0
pre-commit run \
    --config templates/app-repo/.pre-commit-config.yaml \
    --files "$TEST_FILE" 2>&1 | tee /tmp/verify-05.log || RESULT=$?

if [ $RESULT -eq 0 ]; then
    red "VERIFY-05 FAIL: pre-commit allowed os.Getenv(\"OPENAI_KEY\") through"
    red "Layer 1 guardrail is broken — fix templates/app-repo/.pre-commit-config.yaml."
    exit 1
fi

if grep -q "block-secret-shaped-vars" /tmp/verify-05.log; then
    green "VERIFY-05 PASS: block-secret-shaped-vars fired and rejected $TEST_FILE"
    exit 0
fi

red "VERIFY-05 FAIL: pre-commit failed but block-secret-shaped-vars did not fire"
red "Inspect /tmp/verify-05.log for the actual rejection reason."
exit 1
