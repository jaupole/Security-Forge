package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/secforge/lib/errreport"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// Phase 6b-2 commit 5 — reference adoption of `apps/lib/errreport/`.
// Phase 7b.5 — sink swap from NoOp to OTel-span-event.
//
// ADR-0013 § 6 (Multi-layer prevention guardrails — Layer 6: error
// reporting) requires every BFF error path that would reach an external
// reporter (Sentry, Rollbar, OTel error events) to pass through a
// secret-aware Scrubber first.
//
// The reporter is constructed once at startup and held as a
// process-singleton (the BFF is a single-replica pod per ADR-0011).
// Code paths that need it grab the singleton via `errReporter()`. This
// is mildly Go-anti-idiomatic but matches the BFF's existing pattern
// (see slog.Default() usage throughout).
//
// Usage at error-emission sites:
//
//	if err := doRiskyThing(); err != nil {
//	    errReporter().Capture(ctx, err, map[string]string{
//	        "user_id": userID,
//	        "route":   "/api/x",
//	    })
//	    httpJSON(w, 500, errBody("risky_failed"))
//	}
//
// The Scrubber redacts secret-shaped values from BOTH the err.Error()
// message AND every tag value BEFORE reaching the Sink. The OTel sink
// only ever sees post-scrub strings, so even if the OTLP exporter
// somehow leaked downstream the secret value would already be redacted.

var globalReporter *errreport.ScrubbingReporter

// otelSink writes scrubbed errors as span events on the active trace
// span (extracted from ctx). When there is no active recording span
// (e.g., a startup error path before the request handlers wire up,
// or a background goroutine without context plumbing), the sink falls
// back to writing a JSON line on stdout via NoOpSink — Promtail picks
// that up under the helloworld-bff job rather than the secrets-
// guardrails one, but it preserves the audit trail.
//
// Phase 7b.8 verification path: a non-secret error from a request
// handler appears as a span event on that request's trace in Tempo;
// a near-leak (vendor-prefix sigil in err.Error()) is redacted by the
// upstream Scrubber so the span event carries `[redacted]` instead.
type otelSink struct {
	fallback *errreport.NoOpSink
	log      *slog.Logger
}

func newOTelSink(log *slog.Logger) *otelSink {
	return &otelSink{
		fallback: errreport.NewNoOpSink(),
		log:      log,
	}
}

// Capture records the (already-scrubbed) error as a span event on the
// active span. nil err is a no-op (matches NoOpSink semantics).
func (s *otelSink) Capture(ctx context.Context, err error, tags map[string]string) {
	if err == nil {
		return
	}
	span := trace.SpanFromContext(ctx)
	if !span.IsRecording() {
		// No active span (startup error, background goroutine without
		// trace plumbing). Fall back to stdout so Promtail still ships
		// the event — better-than-dropping.
		s.fallback.Capture(ctx, err, tags)
		return
	}
	attrs := make([]attribute.KeyValue, 0, len(tags)+1)
	for k, v := range tags {
		attrs = append(attrs, attribute.String(k, v))
	}
	span.RecordError(err, trace.WithAttributes(attrs...))
	span.SetStatus(codes.Error, err.Error())
}

// initErrReporter constructs the singleton ScrubbingReporter. Called
// exactly once from main(). The Scrubber is the package's default rule
// set (gitleaks-shaped vendor-prefix regexes per
// `apps/lib/errreport/scrubber.go`); the Sink is the OTel-span-event
// sink defined above when OTEL_EXPORTER_OTLP_ENDPOINT is set
// (production posture), or NoOpSink when unset (dev / unit tests).
func initErrReporter(log *slog.Logger) {
	// Sink field on ScrubbingReporter is typed as errreport.Reporter
	// (which is the Capture(ctx, err, tags) interface — both
	// NoOpSink and otelSink satisfy it).
	var sink errreport.Reporter
	sinkName := "noop"
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "" {
		sink = newOTelSink(log)
		sinkName = "otel-span-event"
	} else {
		sink = errreport.NewNoOpSink()
	}
	globalReporter = &errreport.ScrubbingReporter{
		Scrubber: errreport.NewDefaultScrubber(),
		Sink:     sink,
	}
	log.Info("errreport ready",
		"sink", sinkName,
		"phase", "7b.5",
		"adr", "ADR-0013 § 6")
}

// errReporter returns the process-wide reporter. Returns a fail-closed
// no-op shim if initErrReporter wasn't called — callers shouldn't have
// to nil-check and the alternative (panic at first error path) would
// itself be observable as a CrashLoopBackOff pattern, which is worse
// than dropping events silently for the duration of a misconfigured
// startup.
func errReporter() errreport.Reporter {
	if globalReporter == nil {
		return errreport.ReporterFunc(func(_ context.Context, _ error, _ map[string]string) {})
	}
	return globalReporter
}
