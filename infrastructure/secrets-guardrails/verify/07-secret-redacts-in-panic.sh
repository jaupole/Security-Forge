#!/usr/bin/env bash
# Verify 07: Layer 6 (error-reporter scrubbing) — apps/lib/errreport/
# DefaultScrubber redacts a vendor-prefix sigil from the panic message
# captured by ScrubbingReporter before reaching the sink.
#
# Spins up a tiny dockerized Go program that:
#   1. Constructs a ScrubbingReporter with DefaultScrubber + a captureSink.
#   2. Triggers an error containing a sigil.
#   3. Calls reporter.Capture; the captureSink prints what it received.
# We then grep the captured output for the sigil and assert NOT FOUND.
#
# Exit codes:
#   0  — scrubber held; sigil not present in captured payload
#   1  — sigil leaked to the captured payload
#   2  — operator setup issue (docker missing)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-07: docker required"
    exit 2
fi

# Multiple sigils so this exercises every prefix DefaultScrubber covers
# (Stripe live, Stripe test, Slack, GitHub PAT, OpenBao). Skip AWS;
# vendor-prefix additions are an apps/lib/errreport/ ADR-0013 § Re-eval
# trigger, not a verify-script change.
SIGILS=(
    "sk_live_$(printf 'TEST%.0s' {1..8})"
    "sk_test_$(printf 'TEST%.0s' {1..8})"
    "ghp_$(printf 'TEST%.0s' {1..8})"
    "xoxb-1234567890-$(printf 'a%.0s' {1..16})"
    "bao.token-$(printf 'a%.0s' {1..20})"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > go.mod <<'EOF'
module verify07

go 1.25.0

require github.com/secforge/lib v0.0.0

replace github.com/secforge/lib => /secforge-lib
EOF

# Build the Go program with the sigils baked into a slice. We can't
# use a heredoc + bash interpolation without escaping; safer to build
# the array literal with printf.
{
    cat <<'GOEOF'
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/secforge/lib/errreport"
)

type captureSink struct{}

func (captureSink) Capture(_ context.Context, err error, tags map[string]string) {
	fmt.Printf("CAPTURED_ERR: %s\n", err.Error())
	for k, v := range tags {
		fmt.Printf("CAPTURED_TAG: %s=%s\n", k, v)
	}
}

func main() {
	rep := &errreport.ScrubbingReporter{
		Scrubber: errreport.NewDefaultScrubber(),
		Sink:     captureSink{},
	}
	sigils := []string{
GOEOF
    for s in "${SIGILS[@]}"; do
        printf '\t\t"%s",\n' "$s"
    done
    cat <<'GOEOF'
	}
	for _, sig := range sigils {
		err := errors.New("upstream auth failed: " + sig + " expired")
		rep.Capture(context.Background(), err, map[string]string{
			"vendor_token": sig,
			"user_id":      "alice",
		})
	}
}
GOEOF
} > main.go

yellow "VERIFY-07: running ScrubbingReporter chain via dockerized Go"
# Mount target is /secforge-lib, NOT /lib — see verify-06's matching
# comment for the musl-libc shadowing trap.
OUTPUT=$(docker run --rm \
    -v "$REPO_ROOT/apps/lib":/secforge-lib \
    -v "$WORK":/work \
    -w /work \
    -e CGO_ENABLED=0 \
    golang:1.25-alpine sh -c 'go mod tidy -e 2>/dev/null; go run main.go' 2>&1)

echo "$OUTPUT" > /tmp/verify-07.log

LEAKED=0
for sig in "${SIGILS[@]}"; do
    if echo "$OUTPUT" | grep -qF "$sig"; then
        red "VERIFY-07: sigil leaked: $sig"
        LEAKED=1
    fi
done

if [ $LEAKED -ne 0 ]; then
    red "VERIFY-07 FAIL: at least one sigil bypassed the scrubber"
    red "Inspect /tmp/verify-07.log; check apps/lib/errreport/scrubber.go regex."
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "CAPTURED_ERR:"; then
    red "VERIFY-07 FAIL: sink did not receive any Capture calls — program failed?"
    echo "$OUTPUT" | sed 's/^/    /'
    exit 1
fi

green "VERIFY-07 PASS: ${#SIGILS[@]} sigils all redacted before reaching the sink"
exit 0
