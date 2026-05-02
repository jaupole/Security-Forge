package errreport

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// NoOpSink writes scrubbed events as JSON lines to a Writer (default
// os.Stdout). Per ADR-0013 § 6, this is the Phase 6b-2 sink: every
// error path is exercised through ScrubbingReporter today, ensuring
// the scrubber and the wire-up are battle-tested before Phase 7
// connects a real reporter.
//
// Each emitted line is a single JSON object so log shippers (Promtail
// in Phase 7) can parse them as structured events.
type NoOpSink struct {
	Out io.Writer
}

// NewNoOpSink returns a NoOpSink writing to os.Stdout.
func NewNoOpSink() *NoOpSink {
	return &NoOpSink{Out: os.Stdout}
}

// Capture writes a JSON line of {event, message, tags} to s.Out.
// nil err is a no-op. Marshal errors are silently dropped — the sink
// must not itself become an error source for the consumer.
func (s *NoOpSink) Capture(_ context.Context, err error, tags map[string]string) {
	if err == nil {
		return
	}
	if s.Out == nil {
		s.Out = os.Stdout
	}
	payload := struct {
		Event   string            `json:"event"`
		Message string            `json:"message"`
		Tags    map[string]string `json:"tags,omitempty"`
	}{
		Event:   "errreport.captured",
		Message: err.Error(),
		Tags:    tags,
	}
	b, mErr := json.Marshal(payload)
	if mErr != nil {
		return
	}
	fmt.Fprintln(s.Out, string(b))
}
