#!/usr/bin/env bash
# Verify 06: Layer 5 (runtime) — apps/lib/secrets/ Secret type redacts
# via String() / MarshalJSON() so a stray fmt.Printf does not leak the
# value. ADR-0013 § 7 (Hardened mode and runtime hygiene).
#
# Spins up a tiny dockerized Go program that constructs a Secret holding
# a known-shaped value, then fmt.Printfs and json.Marshals it, and
# greps the output for the value. Asserts the value never appears.
#
# Exit codes:
#   0  — redaction held; raw value not present in output
#   1  — redaction broke; raw value leaked to stdout
#   2  — operator setup issue (docker missing)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

if ! command -v docker >/dev/null 2>&1; then
    red "VERIFY-06: docker required (Go toolchain image)"
    exit 2
fi

# Split-and-concat per CLAUDE.md "no secrets in code". The value is a
# synthetic Stripe-shaped string; we never assert its presence anywhere
# except as a negative ("MUST NOT appear").
SIGIL_VALUE="sk_live_$(printf 'TEST%.0s' {1..8})"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Stand up a single-file Go module that imports apps/lib/secrets via
# the same replace pattern as helloworld-bff. The script bind-mounts
# the platform's apps/lib so the local replace target resolves.
cat > go.mod <<'EOF'
module verify06

go 1.25.0

require github.com/secforge/lib v0.0.0

replace github.com/secforge/lib => /lib
EOF

cat > main.go <<EOF
package main

import (
	"encoding/json"
	"fmt"

	libSecrets "github.com/secforge/lib/secrets"
)

func main() {
	s := libSecrets.NewSecret([]byte("$SIGIL_VALUE"))
	// Three deliberately-sloppy emission paths.
	fmt.Println("printf:", s)              // String() must redact
	fmt.Printf("printf-v: %v\n", s)        // String() must redact
	b, _ := json.Marshal(s)
	fmt.Println("json:", string(b))        // MarshalJSON must redact
}
EOF

yellow "VERIFY-06: building + running synthetic emitter via dockerized Go"
OUTPUT=$(docker run --rm \
    -v "$REPO_ROOT/apps/lib":/lib \
    -v "$WORK":/work \
    -w /work \
    -e CGO_ENABLED=0 \
    golang:1.25-alpine sh -c 'go mod tidy -e 2>/dev/null; go run main.go' 2>&1)

echo "$OUTPUT" > /tmp/verify-06.log

if echo "$OUTPUT" | grep -qF "$SIGIL_VALUE"; then
    red "VERIFY-06 FAIL: raw secret value appeared in emitter output:"
    echo "$OUTPUT" | sed 's/^/    /'
    red "apps/lib/secrets/Secret.String or MarshalJSON regressed."
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "redacted"; then
    red "VERIFY-06 FAIL: emission did not contain the [redacted] marker."
    red "Suggests the Secret was empty or the program failed to run:"
    echo "$OUTPUT" | sed 's/^/    /'
    exit 1
fi

green "VERIFY-06 PASS: Secret redacted across String, Printf %v, and MarshalJSON paths"
exit 0
