package apiauth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

// requestIDCtxKey is the typed context key under which ContextWithRequestID
// stores the per-request correlation ID.
type requestIDCtxKey struct{}

// ContextWithRequestID returns ctx with id attached. Phase 9 backends call
// this on the inbound edge so subsequent helpers can read the ID without
// the http.Request handle.
func ContextWithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDCtxKey{}, id)
}

// RequestIDFromContext returns the value attached by ContextWithRequestID,
// or "" if none.
func RequestIDFromContext(ctx context.Context) string {
	v, _ := ctx.Value(requestIDCtxKey{}).(string)
	return v
}

// ErrAuditTimeout is returned by LogHop when the underlying Writer does
// not complete within AuditConfig.WriteTimeout. The line is dropped and
// the dropped-counter is incremented; never blocks the request path.
var ErrAuditTimeout = errors.New("apiauth: audit log write timed out")

const defaultAuditWriteTimeout = 100 * time.Millisecond

// Audit emits one structured JSON log line per hop in a SecForge call chain,
// per the SPIFFE+request-id schema fixed in ADR-0012 § Q4 and surfaced in
// ADR-0014 § Library API surface. Backed by a caller-supplied io.Writer
// (typically os.Stdout — Promtail picks it up to Loki).
type Audit struct {
	cfg     AuditConfig
	dropped int64 // atomic; incremented on Write timeout
}

// NewAudit returns an Audit. The constructor performs no I/O.
func NewAudit(cfg AuditConfig) *Audit {
	if cfg.WriteTimeout == 0 {
		cfg.WriteTimeout = defaultAuditWriteTimeout
	}
	return &Audit{cfg: cfg}
}

// hopLine is the canonical schema. Field order matches the JSON tag order
// per ADR-0012 § Q4 — Go's encoding/json marshals struct fields in declared
// order, which is the contract the schema relies on.
type hopLine struct {
	RequestID        string `json:"request_id"`
	HopIndex         int    `json:"hop_index"`
	CallerWorkloadID string `json:"caller_workload_id"`
	CallerUserSub    string `json:"caller_user_sub"`
	TargetAudience   string `json:"target_audience"`
	Timestamp        string `json:"timestamp"`
	Endpoint         string `json:"endpoint"`
	Status           int    `json:"status"`
}

// LogHop emits a single audit line for one hop in a call chain.
//
// request_id resolution: if X-Request-ID is set on req, it is used as-is.
// Otherwise a fresh ID is generated via randomID() (16 bytes base64url),
// written back to req.Header so downstream helpers in the same process
// see it, and propagated through the response if Wrap is in the chain.
//
// endpoint deliberately omits the query string (PII safety; query strings
// often carry user identifiers in the wild).
//
// MUST NOT panic on any input. On timeout, drops the line and returns
// ErrAuditTimeout — never blocks the request path beyond
// AuditConfig.WriteTimeout (default 100ms).
func (a *Audit) LogHop(req *http.Request, hopIndex int, callerWorkloadID, callerUserSub, targetAudience string, status int) error {
	if req == nil {
		return errors.New("apiauth: LogHop called with nil request")
	}

	// Resolve / generate request_id.
	id := req.Header.Get("X-Request-ID")
	if id == "" {
		id = randomID()
		req.Header.Set("X-Request-ID", id)
	}

	// Endpoint = "METHOD /path" — query string is intentionally dropped.
	path := "/"
	if req.URL != nil && req.URL.Path != "" {
		path = req.URL.Path
	}
	endpoint := fmt.Sprintf("%s %s", req.Method, path)

	line := hopLine{
		RequestID:        id,
		HopIndex:         hopIndex,
		CallerWorkloadID: callerWorkloadID,
		CallerUserSub:    callerUserSub,
		TargetAudience:   targetAudience,
		Timestamp:        a.now().UTC().Format("2006-01-02T15:04:05.000Z"),
		Endpoint:         endpoint,
		Status:           status,
	}

	buf, err := json.Marshal(line)
	if err != nil {
		return err
	}
	buf = append(buf, '\n')

	// Bounded-time write: spawn a goroutine so a slow Writer can't hang
	// the request path. If the timeout fires first, drop the line and
	// increment the dropped-counter; the goroutine eventually completes
	// in the background.
	done := make(chan error, 1)
	go func() {
		defer func() {
			// The Writer can panic (e.g., closed pipe); never let that
			// take down the caller.
			if r := recover(); r != nil {
				done <- fmt.Errorf("apiauth: audit Writer panicked: %v", r)
			}
		}()
		_, werr := a.cfg.Writer.Write(buf)
		done <- werr
	}()

	select {
	case werr := <-done:
		return werr
	case <-time.After(a.cfg.WriteTimeout):
		atomic.AddInt64(&a.dropped, 1)
		return ErrAuditTimeout
	}
}

// Dropped returns the cumulative count of audit lines dropped due to
// WriteTimeout. Surfacing this lets operators wire a Prometheus counter
// against it.
func (a *Audit) Dropped() int64 {
	return atomic.LoadInt64(&a.dropped)
}

func (a *Audit) now() time.Time {
	if a.cfg.Clock != nil {
		return a.cfg.Clock()
	}
	return time.Now()
}
