package errreport

import (
	"regexp"
)

// DefaultScrubber implements the canonical SecForge rule set per
// ADR-0013 § 6:
//
//   - High-entropy secret prefixes: sk_live_, sk_test_, xoxb-, ghp_,
//     gho_, bao.<token>, JWT-shaped (eyJ...).
//   - Env-var-shaped key/value pairs where the key matches *KEY*,
//     *SECRET*, *TOKEN*, *PASSWORD*, *CREDENTIAL* (same banlist as the
//     Kyverno admission policy in commit 4).
//   - The Secret type's String marker — never matched literally
//     because the type already redacts; included as a defense-in-depth
//     rule so a future regression in Secret.String would still fail
//     here.
//
// Concurrent-safe: regexp.Regexp methods are documented as safe for
// concurrent use after compilation.
type DefaultScrubber struct{}

// NewDefaultScrubber returns a Scrubber with the canonical rule set.
func NewDefaultScrubber() Scrubber {
	return &DefaultScrubber{}
}

var (
	// Secret-prefix regex. Each alternative is anchored to a recognizable
	// vendor prefix and a minimum trailing-character count to avoid
	// false-positive matches against short identifiers. Body uses \w
	// (= [A-Za-z0-9_]) so canaries with underscores in the body
	// (e.g., sk_live_CANARY_DO_NOT_LEAK_XYZ) are still caught.
	secretPrefixRe = regexp.MustCompile(
		`sk_live_\w{8,}` +
			`|sk_test_\w{8,}` +
			`|xoxb-[\w-]{8,}` +
			`|ghp_\w{16,}` +
			`|gho_\w{16,}` +
			`|bao\.[\w-]{16,}` +
			`|eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}`,
	)

	// JSON-shaped {"<NAME>":"<VALUE>"} where <NAME> contains a
	// banlisted substring. (?i) flag = case-insensitive, so lowercase
	// keys like "my_credential" or "password" are caught alongside
	// the conventional uppercase forms. Capture group 1 = key+colon+
	// open-quote; group 2 = closing quote. Replacement keeps the
	// structure and substitutes the value with [redacted].
	envShapedJSONRe = regexp.MustCompile(
		`(?i)("[^"]*(?:KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)[^"]*"\s*:\s*")[^"]*(")`,
	)

	// k=v form in command-line / env-dump shapes (e.g.,
	// "STRIPE_API_KEY=sk_live_abc"). Captures the key+equals; the
	// value is replaced. Conventional uppercase env-var names only —
	// lowercase k=v in shell scripts is uncommon enough that the
	// false-positive cost outweighs the catch.
	envShapedKVRe = regexp.MustCompile(
		`([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)[A-Z0-9_]*=)\S+`,
	)

	redactedMarker = []byte("[redacted]")
)

// Scrub returns a copy of payload with all matched secret patterns
// replaced with "[redacted]". Returns the input slice unchanged when
// it's empty.
func (s *DefaultScrubber) Scrub(payload []byte) []byte {
	if len(payload) == 0 {
		return payload
	}
	out := secretPrefixRe.ReplaceAll(payload, redactedMarker)
	out = envShapedJSONRe.ReplaceAll(out, []byte(`${1}[redacted]${2}`))
	out = envShapedKVRe.ReplaceAll(out, []byte(`${1}[redacted]`))
	return out
}
