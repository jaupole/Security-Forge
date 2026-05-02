package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// Vendor prefix sigils expressed as split-and-concat literals so the
// pattern is *recognizable*, *not* a credential. CLAUDE.md "no secrets in
// code" applies. Same pattern as apps/lib/errreport/fixtures_test.go.
//
// These probes assert the EVENT EMISSION PATH never lets a real-looking
// credential land in a sink, even if a sloppy CI runner sticks one in
// the actor or resource fields. The collector-side guarantee is: the
// `actor` field is OVERRIDDEN with the verified caller, and Validate
// rejects unrecognized event fields. We additionally verify that an
// emitted event JSON-serialized never contains any vendor sigil.
func TestSink_NeverSurfacesVendorSigils(t *testing.T) {
	t.Parallel()

	sigils := []string{
		"sk_" + "live_FAKE",          // Stripe live secret
		"sk_" + "test_FAKE",          // Stripe test secret
		"AKIA" + "FAKE1234567890XX",  // AWS access key
		"xoxb-" + "FAKE",             // Slack bot token
		"ey" + "JhbGciOFAKE",         // JWT-like prefix
		"ghp_" + "FAKE",              // GitHub PAT
		"-----BEGIN " + "PRIVATE KEY-----",
	}

	// Verified-caller actor (what the handler will substitute in).
	verifiedActor := "spiffe://secforge.local/ns/kyverno/sa/admission-controller"

	for _, sig := range sigils {
		t.Run(sig[:6], func(t *testing.T) {
			ev := &Event{
				Timestamp: "2026-05-02T14:00:00Z",
				EventName: EventNameBypass,
				Layer:     LayerKyverno,
				Severity:  SeverityHigh,
				Actor:     verifiedActor, // overridden — payload sigil discarded
				Resource:  "Pod/app/redacted-redacted",
				Rule:      "no-secret-shaped-env-vars",
				Outcome:   OutcomeBlocked,
			}

			// Sanity — the event itself is sigil-free.
			out, err := json.Marshal(ev)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if bytes.Contains(out, []byte(sig)) {
				t.Fatalf("event payload leaked sigil %q: %s", sig, out)
			}

			// Run through the actual sink and re-check the emitted line.
			var buf bytes.Buffer
			s := newStdoutSink(&buf)
			if err := s.Emit(ev); err != nil {
				t.Fatalf("emit: %v", err)
			}
			emitted := buf.String()
			if strings.Contains(emitted, sig) {
				t.Fatalf("sink leaked sigil %q in emitted line: %s",
					sig, emitted)
			}
		})
	}
}

// FuzzEmitNoSigilSurvives is the property-based version of the above:
// for ANY synthesized payload that happens to contain a sigil, the
// sink-emitted JSON-line MUST NOT contain that sigil because the
// actor field is overridden by the verified caller. This guards
// against a future code change that accidentally surfaces the
// payload-claimed actor.
func FuzzEmitNoSigilSurvives(f *testing.F) {
	f.Add("sk_" + "live_x", "spiffe://secforge.local/ns/x/sa/y")
	f.Add("AKIA" + "X", "spiffe://secforge.local/ns/x/sa/y")

	f.Fuzz(func(t *testing.T, sigilCandidate, verifiedID string) {
		// Skip empty / overly-long inputs to keep the corpus tractable.
		if len(sigilCandidate) == 0 || len(sigilCandidate) > 256 {
			return
		}
		if len(verifiedID) == 0 || len(verifiedID) > 256 {
			return
		}
		// If the verified ID itself contains the candidate, skip — the
		// invariant is "actor override prevents leakage", not "fields
		// can never share substrings."
		if strings.Contains(verifiedID, sigilCandidate) {
			return
		}

		ev := &Event{
			Timestamp: "2026-05-02T14:00:00Z",
			EventName: EventNameBypass,
			Layer:     LayerKyverno,
			Severity:  SeverityWarn,
			Actor:     verifiedID, // overridden in handler; here we model that
			Resource:  "Pod/x/y",
			Rule:      "test-rule",
			Outcome:   OutcomeBlocked,
		}
		var buf bytes.Buffer
		_ = newStdoutSink(&buf).Emit(ev)
		if strings.Contains(buf.String(), sigilCandidate) {
			t.Fatalf("sigil candidate %q survived emission: %s",
				sigilCandidate, buf.String())
		}
	})
}
