package errreport

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestScrubbingReporter_RunsScrubberBeforeSink(t *testing.T) {
	// Verifies the explicit ADR-0013 § 6 invariant: every Capture call
	// passes through the Scrubber before reaching the Sink.

	var mu sync.Mutex
	var scrubberCalls [][]byte
	var sinkErr error
	var sinkTags map[string]string

	scrubber := ScrubberFunc(func(b []byte) []byte {
		mu.Lock()
		defer mu.Unlock()
		// Take a copy because b's backing array is the caller's.
		c := make([]byte, len(b))
		copy(c, b)
		scrubberCalls = append(scrubberCalls, c)
		return []byte("scrubbed:" + string(b))
	})

	sink := ReporterFunc(func(_ context.Context, err error, tags map[string]string) {
		mu.Lock()
		defer mu.Unlock()
		sinkErr = err
		sinkTags = tags
	})

	r := &ScrubbingReporter{Scrubber: scrubber, Sink: sink}
	r.Capture(context.Background(),
		errors.New("oops "+fakeStripeLive),
		map[string]string{"user": "alice", "key": fakeGithubPAT},
	)

	mu.Lock()
	defer mu.Unlock()

	if len(scrubberCalls) != 3 {
		// 1 for err.Error() + 2 for tag values.
		t.Fatalf("scrubber calls = %d, want 3 (err + 2 tags)", len(scrubberCalls))
	}
	if sinkErr == nil {
		t.Fatalf("sink received nil error")
	}
	if !strings.HasPrefix(sinkErr.Error(), "scrubbed:") {
		t.Fatalf("sink saw unscrubbed err: %q", sinkErr.Error())
	}
	for k, v := range sinkTags {
		if !strings.HasPrefix(v, "scrubbed:") {
			t.Fatalf("sink saw unscrubbed tag %q=%q", k, v)
		}
	}
}

func TestScrubbingReporter_NilErr_NoOp(t *testing.T) {
	called := false
	sink := ReporterFunc(func(_ context.Context, _ error, _ map[string]string) {
		called = true
	})
	r := &ScrubbingReporter{Scrubber: NewDefaultScrubber(), Sink: sink}
	r.Capture(context.Background(), nil, map[string]string{"a": "b"})
	if called {
		t.Fatalf("Capture(nil err) must not invoke Sink")
	}
}

func TestScrubbingReporter_NilScrubber_FailsClosed(t *testing.T) {
	called := false
	sink := ReporterFunc(func(_ context.Context, _ error, _ map[string]string) {
		called = true
	})
	r := &ScrubbingReporter{Scrubber: nil, Sink: sink}
	r.Capture(context.Background(), errors.New("boom "+fakeStripeLive), nil)
	if called {
		t.Fatalf("Capture without Scrubber must NOT invoke Sink (fail-closed)")
	}
}

func TestScrubbingReporter_NilSink_NoOp(t *testing.T) {
	r := &ScrubbingReporter{Scrubber: NewDefaultScrubber(), Sink: nil}
	// Should not panic.
	r.Capture(context.Background(), errors.New("boom"), nil)
}

func TestScrubbingReporter_DoesNotMutateCaller(t *testing.T) {
	canary := fakeStripeLive
	tags := map[string]string{"STRIPE_KEY": canary}
	originalErr := errors.New("orig " + canary)
	originalErrText := originalErr.Error()

	r := &ScrubbingReporter{
		Scrubber: NewDefaultScrubber(),
		Sink:     ReporterFunc(func(_ context.Context, _ error, _ map[string]string) {}),
	}
	r.Capture(context.Background(), originalErr, tags)

	if originalErr.Error() != originalErrText {
		t.Fatalf("caller's err mutated: %q", originalErr.Error())
	}
	if tags["STRIPE_KEY"] != canary {
		t.Fatalf("caller's tags mutated: %q", tags["STRIPE_KEY"])
	}
}

func TestNoOpSink_WritesJSONLine(t *testing.T) {
	var buf strings.Builder
	s := &NoOpSink{Out: &buf}

	s.Capture(context.Background(),
		errors.New("oops"),
		map[string]string{"user": "alice"},
	)

	out := buf.String()
	if !strings.Contains(out, `"event":"errreport.captured"`) {
		t.Fatalf("missing event tag: %s", out)
	}
	if !strings.Contains(out, `"message":"oops"`) {
		t.Fatalf("missing message: %s", out)
	}
	if !strings.HasSuffix(out, "\n") {
		t.Fatalf("output missing newline (must be JSON-line for Promtail): %s", out)
	}
}

func TestNoOpSink_NilErr_NoOp(t *testing.T) {
	var buf strings.Builder
	s := &NoOpSink{Out: &buf}
	s.Capture(context.Background(), nil, nil)
	if buf.Len() != 0 {
		t.Fatalf("nil err must not write: %q", buf.String())
	}
}

func TestEndToEnd_DefaultScrubber_DefaultSink(t *testing.T) {
	// Wire the real components and assert the canary doesn't reach
	// the sink output. canary is split-concatenated via the fixture
	// helpers so gitleaks doesn't flag this file (CLAUDE.md "no
	// secrets in code, ever").
	canary := pfxStripeLive + "CANARY_DO_NOT_LEAK_X9Z2_AAAA"

	var buf strings.Builder
	r := &ScrubbingReporter{
		Scrubber: NewDefaultScrubber(),
		Sink:     &NoOpSink{Out: &buf},
	}
	r.Capture(context.Background(),
		errors.New("payment failed: "+canary),
		map[string]string{"STRIPE_API_KEY": canary},
	)

	out := buf.String()
	if strings.Contains(out, canary) {
		t.Fatalf("canary leaked in sink output: %s", out)
	}
	if !strings.Contains(out, "[redacted]") {
		t.Fatalf("output missing redaction marker: %s", out)
	}
}
