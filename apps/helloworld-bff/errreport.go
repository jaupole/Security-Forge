package main

import (
	"context"
	"log/slog"

	"github.com/secforge/lib/errreport"
)

// Phase 6b-2 commit 5 — reference adoption of `apps/lib/errreport/`.
// ADR-0013 § 6 (Multi-layer prevention guardrails — Layer 6: error
// reporting) requires every BFF error path that would reach an external
// reporter (Sentry, Rollbar, OTel error events) to pass through a
// secret-aware Scrubber first. Phase 6b-2 wires the scrubber into a
// no-op Sink so the chain is exercised in production today; Phase 7
// swaps the Sink to a real reporter without touching this file.
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
// message AND every tag value before reaching the Sink. Phase 7 only
// needs to swap NewNoOpSink() for the production reporter.

var globalReporter *errreport.ScrubbingReporter

// initErrReporter constructs the singleton ScrubbingReporter. Called
// exactly once from main(). The Scrubber is the package's default rule
// set (gitleaks-shaped vendor-prefix regexes per
// `apps/lib/errreport/scrubber.go`); the Sink is a no-op writer that
// drops events on the floor — Phase 7 swaps it for Sentry/Rollbar/OTel.
func initErrReporter(log *slog.Logger) {
	globalReporter = &errreport.ScrubbingReporter{
		Scrubber: errreport.NewDefaultScrubber(),
		Sink:     errreport.NewNoOpSink(),
	}
	log.Info("errreport ready",
		"sink", "noop",
		"phase", "6b-2",
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
