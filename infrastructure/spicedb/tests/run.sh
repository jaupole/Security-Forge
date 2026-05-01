#!/usr/bin/env bash
# Validate the four assertion-test files against SpiceDB's `zed validate`.
#
# We don't have `zed` installed locally; instead we run validate inside
# a one-shot Job using the official zed image. This exercises the
# parsed schema and the assertions without requiring a running SpiceDB
# (validate is a pure function of the file contents).
#
# Re-run after any change to schema.zed or to a test file.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZED_IMAGE="authzed/zed:v1.0.0"

green() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; FAILED=1; }

FAILED=0

for testfile in "$HERE"/*.yaml; do
    name=$(basename "$testfile")
    # Run zed validate against the file. validate exits non-zero on any
    # assertion failure or schema parse error and prints to stderr.
    if docker run --rm -i "$ZED_IMAGE" validate /dev/stdin <"$testfile" >/tmp/zed-validate.out 2>&1; then
        green "$name"
    else
        red "$name"
        sed 's/^/      | /' </tmp/zed-validate.out >&2
    fi
done

if [ "$FAILED" = "0" ]; then
    printf '\n\033[32m== ALL VALIDATIONS PASSED ==\033[0m\n'
    exit 0
fi
printf '\n\033[31m== FAILURES ABOVE ==\033[0m\n'
exit 1
