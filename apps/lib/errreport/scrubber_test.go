package errreport

import (
	"bytes"
	"testing"
)

func TestDefaultScrubber_StripePrefix(t *testing.T) {
	s := NewDefaultScrubber()
	in := []byte("payment failed for " + fakeStripeLive)
	out := s.Scrub(in)
	if bytes.Contains(out, []byte(pfxStripeLive+"abc")) {
		t.Fatalf("Stripe key not scrubbed: %s", out)
	}
	if !bytes.Contains(out, []byte("[redacted]")) {
		t.Fatalf("redaction marker missing: %s", out)
	}
}

func TestDefaultScrubber_AllSecretPrefixes(t *testing.T) {
	// Fixtures are constructed via split-concatenated prefixes from
	// fixtures_test.go so this file doesn't trip gitleaks. CLAUDE.md
	// "no secrets in code" applies even to test data.
	cases := []struct {
		name string
		in   string
	}{
		{"stripe live", fakeStripeLive},
		{"stripe test", fakeStripeTest},
		{"slack bot", fakeSlackBot},
		{"github pat", fakeGithubPAT},
		{"github oauth", fakeGithubOAuth},
		{"openbao", fakeOpenBao},
		{"jwt", fakeJWT},
	}
	s := NewDefaultScrubber()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out := s.Scrub([]byte(c.in))
			if bytes.Contains(out, []byte(c.in)) {
				t.Fatalf("%s prefix not scrubbed; in=%q out=%s", c.name, c.in, out)
			}
		})
	}
}

func TestDefaultScrubber_JSONShape(t *testing.T) {
	cases := []string{
		`{"STRIPE_API_KEY":"some-value-here"}`,
		`{"DB_PASSWORD":"hunter2"}`,
		`{"GITHUB_TOKEN":"` + pfxGithubPAT + `abc"}`,
		`{"my_credential":"secret"}`,
		`{"random_key":"val"}`,
	}
	s := NewDefaultScrubber()
	for _, in := range cases {
		out := s.Scrub([]byte(in))
		if bytes.Contains(out, []byte(`":"some-value-here"`)) ||
			bytes.Contains(out, []byte(`":"hunter2"`)) ||
			bytes.Contains(out, []byte(`":"secret"`)) {
			t.Fatalf("JSON value not scrubbed: in=%q out=%s", in, out)
		}
	}
}

func TestDefaultScrubber_KVShape(t *testing.T) {
	in := []byte("STRIPE_API_KEY=" + fakeStripeLive + " OPENAI_API_KEY=hunter2 OTHER=keep")
	out := s_default(t).Scrub(in)
	if bytes.Contains(out, []byte(pfxStripeLive+"abc")) {
		t.Fatalf("STRIPE_API_KEY value not scrubbed: %s", out)
	}
	if bytes.Contains(out, []byte("=hunter2")) {
		t.Fatalf("OPENAI_API_KEY value not scrubbed: %s", out)
	}
	// Non-banlisted env var is preserved.
	if !bytes.Contains(out, []byte("OTHER=keep")) {
		t.Fatalf("non-banlisted var should be preserved: %s", out)
	}
}

func TestDefaultScrubber_DoesNotOverScrub(t *testing.T) {
	in := []byte(`hello world; integer=42; user=alice`)
	out := s_default(t).Scrub(in)
	if !bytes.Equal(in, out) {
		t.Fatalf("non-secret payload should pass through unchanged.\n  in:  %s\n  out: %s", in, out)
	}
}

func TestDefaultScrubber_EmptyInput(t *testing.T) {
	out := s_default(t).Scrub([]byte{})
	if len(out) != 0 {
		t.Fatalf("empty input should return empty: %s", out)
	}
}

func TestDefaultScrubber_PartialPrefixNotMatched(t *testing.T) {
	// pfxStripeLive + 5 chars is below the {8,} regex bound — must
	// not be over-eagerly redacted.
	in := []byte(pfxStripeLive + "short")
	out := s_default(t).Scrub(in)
	if !bytes.Equal(in, out) {
		t.Fatalf("short pseudo-prefix should not match (insufficient char count): %s", out)
	}
}

// FuzzDefaultScrubber_NoSecretSurvives is the mandatory ADR-0013 § 6
// invariant: no secret-shaped pattern may survive a Scrub call,
// regardless of input. Seed corpus uses split-concatenated fixtures
// to dodge gitleaks (CLAUDE.md "no secrets in code").
func FuzzDefaultScrubber_NoSecretSurvives(f *testing.F) {
	f.Add(fakeStripeLive)
	f.Add(`{"STRIPE_API_KEY":"` + fakeStripeTest + `"}`)
	f.Add(fakeJWT)
	f.Add("plain text no secrets at all")
	f.Add(`{"DB_PASSWORD":"hunter2","port":5432}`)
	f.Add("STRIPE_API_KEY=" + fakeStripeLive)
	f.Add("<empty>")
	f.Add(fakeGithubPAT + " " + fakeOpenBao)

	s := NewDefaultScrubber()

	f.Fuzz(func(t *testing.T, in string) {
		out := s.Scrub([]byte(in))
		if secretPrefixRe.Match(out) {
			t.Errorf("secret-prefix pattern survived Scrub.\n  in:  %q\n  out: %q", in, out)
		}
	})
}

func s_default(t *testing.T) Scrubber {
	t.Helper()
	return NewDefaultScrubber()
}
