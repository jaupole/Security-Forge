package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"github.com/secforge/lib/errreport"
)

// captureSink records every Capture call so the test can assert on the
// post-scrub message content.
type captureSink struct {
	mu     sync.Mutex
	errs   []error
	tagSet []map[string]string
}

func (s *captureSink) Capture(_ context.Context, err error, tags map[string]string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.errs = append(s.errs, err)
	cp := make(map[string]string, len(tags))
	for k, v := range tags {
		cp[k] = v
	}
	s.tagSet = append(s.tagSet, cp)
}

func TestErrReporter_RedactsVendorSigilsBeforeSink(t *testing.T) {
	// Wire a ScrubbingReporter directly (mirrors initErrReporter's
	// composition) but with the capture sink instead of NoOpSink so we
	// can assert on what reached the sink.
	sink := &captureSink{}
	rep := &errreport.ScrubbingReporter{
		Scrubber: errreport.NewDefaultScrubber(),
		Sink:     sink,
	}

	// Split-and-concat sigils so no real-looking credential lives in
	// source. Same hygiene pattern as apps/lib/errreport/fixtures_test.go.
	// Selected to cover the rule set DefaultScrubber actually carries —
	// vendor prefix rule additions are an ADR-0013 § Re-evaluation
	// trigger and live in apps/lib/errreport/, not this consumer test.
	sigils := []string{
		"sk_" + "live_FAKE0123456789ABCDEF0123",
		"sk_" + "test_FAKE0123456789ABCDEF0123",
		"ghp_" + "FAKE0123456789ABCDEFGHIJKLMNOPQRSTUVWX",
		"xoxb-" + "FAKE-1234567890-1234567890-abcdefghij",
		"bao." + "FAKE-token-abcdefghijklmnop",
	}

	for _, sig := range sigils {
		t.Run(sig[:6], func(t *testing.T) {
			err := errors.New("upstream auth failed: " + sig + " expired")
			rep.Capture(context.Background(), err, map[string]string{
				"user_id":   "alice",
				"vendor_id": sig,
			})
		})
	}

	// Now examine what the sink received. The scrubber must have
	// redacted every sigil from BOTH the err.Error() and tag values.
	for i, e := range sink.errs {
		for _, sig := range sigils {
			if strings.Contains(e.Error(), sig) {
				t.Fatalf("captured err[%d] leaked sigil %q: %s", i, sig, e.Error())
			}
		}
	}
	for i, tags := range sink.tagSet {
		for _, sig := range sigils {
			for k, v := range tags {
				if strings.Contains(v, sig) {
					t.Fatalf("captured tag[%d][%s] leaked sigil %q: %s", i, k, sig, v)
				}
			}
		}
	}
}

func TestErrReporter_FailClosedShim(t *testing.T) {
	// Until initErrReporter runs, errReporter() returns a fail-closed
	// no-op. It MUST NOT panic on any input — error paths run before
	// startup completes (e.g., during loadCfg).
	globalReporter = nil
	rep := errReporter()
	if rep == nil {
		t.Fatal("errReporter must never return nil")
	}
	// Call shape must accept nil and arbitrary tags without panicking.
	rep.Capture(context.Background(), errors.New("startup error"), map[string]string{"k": "v"})
	rep.Capture(context.Background(), nil, nil)
}

func TestInitErrReporter_BuildsScrubbingReporter(t *testing.T) {
	globalReporter = nil
	initErrReporter(slog.New(slog.NewTextHandler(io.Discard, nil)))
	if globalReporter == nil {
		t.Fatal("globalReporter not set after initErrReporter")
	}
	if globalReporter.Scrubber == nil {
		t.Fatal("Scrubber missing")
	}
	if globalReporter.Sink == nil {
		t.Fatal("Sink missing")
	}
	// errReporter() should now route to the configured Scrubbing chain.
	if errReporter() != globalReporter {
		t.Fatal("errReporter() returned a different instance than globalReporter")
	}
}
