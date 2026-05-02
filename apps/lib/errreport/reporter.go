// Package errreport is the error-reporter wire-in for SecForge first-class
// apps. Per ADR-0013 § 6 (multi-layer prevention guardrails, layer 6:
// error reporting), every error path that would reach a Sentry/Rollbar/
// OTel sink runs through a Scrubber first.
//
// Phase 6b-2 ships the scrubber WIRED INTO A NO-OP SINK (sink.NoOpSink),
// not just committed as inert middleware. This closes the "scrubber
// exists but isn't running" gap — every error path is exercised today,
// even though the real reporter is not yet wired up.
//
// Phase 7 swaps the Sink implementation for the real reporter (Sentry/
// Rollbar/OTel error events). The Scrubber is unchanged.
//
// Wire-in pattern (consumer side, lands in commit 5):
//
//	rep := &errreport.ScrubbingReporter{
//	    Scrubber: errreport.NewDefaultScrubber(),
//	    Sink:     errreport.NewNoOpSink(),
//	}
//	rep.Capture(ctx, err, map[string]string{"user_id": userID})
//
// Phase 7 changes one line per app: NewNoOpSink() → NewSentrySink(...).
package errreport

import (
	"context"
	"errors"
)

// Reporter is the destination for captured errors. Production sinks
// (Sentry, Rollbar, OTel error events) implement this. The Phase 6b-2
// no-op sink also implements it.
type Reporter interface {
	Capture(ctx context.Context, err error, tags map[string]string)
}

// ReporterFunc adapts a function to the Reporter interface. Useful in
// tests and for inline composition.
type ReporterFunc func(ctx context.Context, err error, tags map[string]string)

// Capture invokes the underlying function.
func (f ReporterFunc) Capture(ctx context.Context, err error, tags map[string]string) {
	f(ctx, err, tags)
}

// Scrubber applies redaction rules to a payload. Implementations MUST
// be concurrent-safe. Scrub MUST NOT mutate its input; return a fresh
// slice (or the input slice unchanged if no rules matched).
type Scrubber interface {
	Scrub(payload []byte) []byte
}

// ScrubberFunc adapts a function to the Scrubber interface. Useful for
// tests that want to assert a custom scrubbing rule fired.
type ScrubberFunc func(payload []byte) []byte

// Scrub invokes the underlying function.
func (f ScrubberFunc) Scrub(payload []byte) []byte {
	return f(payload)
}

// ScrubbingReporter is the wire-in middleware: every Capture call
// passes the err's message and tag values through Scrubber before
// reaching Sink. The caller's err and tags are NOT mutated.
//
// Both Scrubber and Sink are required at construction; nil Sink makes
// Capture a no-op (silent), nil Scrubber returns Capture early without
// invoking Sink (fail-closed: missing scrubber means we'd send raw
// values to a real sink, which is the failure mode this whole package
// exists to prevent).
type ScrubbingReporter struct {
	Scrubber Scrubber
	Sink     Reporter
}

// Capture scrubs err.Error() and every tag value, then forwards to
// Sink with a freshly-constructed error and tags map.
func (r *ScrubbingReporter) Capture(ctx context.Context, err error, tags map[string]string) {
	if err == nil {
		return
	}
	if r.Scrubber == nil || r.Sink == nil {
		// Fail-closed: never invoke Sink without a Scrubber. Silent
		// drop is preferable to leaking a raw value into a real
		// reporter when the wiring is misconfigured.
		return
	}
	cleanMsg := r.Scrubber.Scrub([]byte(err.Error()))
	cleanErr := errors.New(string(cleanMsg))
	cleanTags := make(map[string]string, len(tags))
	for k, v := range tags {
		cleanTags[k] = string(r.Scrubber.Scrub([]byte(v)))
	}
	r.Sink.Capture(ctx, cleanErr, cleanTags)
}
