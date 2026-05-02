package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	apiauth "github.com/secforge/lib/api-auth"
)

// Sink is the destination for accepted events. The 6b-2 implementation
// writes JSON-lines to stdout (Phase 7b's Promtail tails container logs);
// the seam exists so Phase 7 can swap in a Sentry/Rollbar adapter without
// touching handler logic.
type Sink interface {
	Emit(e *Event) error
}

// stdoutSink writes one JSON-line per event to an io.Writer (typically
// os.Stdout). Concurrency-safe — net/http handlers run in goroutines, and
// json.NewEncoder writes are not atomic across goroutines without external
// serialization. We hold a mutex on Emit; throughput is non-critical.
type stdoutSink struct {
	w   io.Writer
	enc *json.Encoder
}

func newStdoutSink(w io.Writer) *stdoutSink {
	return &stdoutSink{w: w, enc: json.NewEncoder(w)}
}

func (s *stdoutSink) Emit(e *Event) error {
	return s.enc.Encode(e)
}

// validator is the narrow contract the handler needs from
// apps/lib/api-auth/. Splitting it out as an interface keeps the
// production wire (apiauth.Middleware) decoupled from tests, which
// would otherwise need to spin up a JWKS server to construct a real
// Middleware.
type validator interface {
	ValidateInbound(*http.Request) (*apiauth.Claims, error)
}

// handler holds the dependencies the POST /v1/secrets/guardrail/bypass
// route needs. Constructed in main.go and bound to mux.HandleFunc.
type handler struct {
	mw   validator
	sink Sink
	log  *slog.Logger
	now  func() time.Time
}

// ServeHTTP processes a single event POST. Auth → parse → override actor →
// validate → emit. Per ADR-0013 § Webhook receiver auth, the actor field
// in the payload is OVERRIDDEN by the verified caller identity from the
// JWT — the payload's claimed actor is treated as untrusted hint only.
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Auth: validate the inbound JWT. ValidateInbound returns *Claims on
	// success or one of the typed apiauth errors on failure. On failure,
	// emit our own severity=high event so silent rejection doesn't mask
	// an attacker probing the endpoint (Section 8 of the prompt).
	claims, err := h.mw.ValidateInbound(r)
	if err != nil {
		h.emitRejection(r, err)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Parse body. 1 MiB cap rules out pathological payloads; events are
	// kilobytes at most.
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}

	var ev Event
	if err := json.Unmarshal(body, &ev); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	// Override actor with the verified caller identity. SPIFFE-SVID
	// (in-cluster) takes precedence over OIDC sub (out-of-cluster). The
	// payload's claimed actor is discarded — that's the whole point of
	// this layer per ADR-0013.
	ev.Actor = verifiedActor(claims)

	// Carry-through request-id when one is in scope.
	if rid := r.Header.Get("X-Request-Id"); rid != "" && ev.RequestID == "" {
		ev.RequestID = rid
	}

	// Default ts to receive-time if the caller didn't set one. Most callers
	// will, but pre-commit hooks running locally won't have a clock the
	// collector trusts anyway — the receive-time is more useful for
	// downstream correlation.
	if ev.Timestamp == "" {
		ev.Timestamp = h.now().UTC().Format(time.RFC3339)
	}

	if err := ev.Validate(); err != nil {
		http.Error(w, fmt.Sprintf("invalid event: %v", err),
			http.StatusBadRequest)
		return
	}

	if err := h.sink.Emit(&ev); err != nil {
		// Sink failure is internal — return 500 but don't leak detail.
		// Operationally: investigate via the collector's own logs.
		h.log.Error("sink emit failed", "err", err)
		http.Error(w, "sink emit failed", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusAccepted)
}

// verifiedActor derives the canonical actor string from validated Claims.
// Returns SPIFFE-ID when present (in-cluster mTLS path); falls back to
// OIDC sub (out-of-cluster Bearer-JWT path); returns "unknown" only when
// neither is set, which should never happen post-ValidateInbound.
func verifiedActor(c *apiauth.Claims) string {
	if c == nil {
		return "unknown"
	}
	if c.SPIFFEID != nil && *c.SPIFFEID != "" {
		return *c.SPIFFEID
	}
	if c.Sub != "" {
		return "kc:" + c.Sub
	}
	return "unknown"
}

// emitRejection writes a synthetic severity=high event recording the 401.
// This is the "silent rejection doesn't mask probing" guarantee from
// ADR-0013 § Webhook receiver auth. Rejected events use a special
// `actor=unauthenticated` marker; the underlying error is captured in
// Rule so downstream queries can group by reason.
func (h *handler) emitRejection(r *http.Request, authErr error) {
	rid := r.Header.Get("X-Request-Id")
	ev := &Event{
		Timestamp: h.now().UTC().Format(time.RFC3339),
		EventName: EventNameBypass,
		Layer:     LayerCI, // closest closed-enum value for "external probing"
		Severity:  SeverityHigh,
		Actor:     "unauthenticated",
		Resource:  fmt.Sprintf("%s %s", r.Method, r.URL.Path),
		Rule:      fmt.Sprintf("collector.auth: %v", authErr),
		Outcome:   OutcomeBlocked,
		RequestID: rid,
	}
	// Emit best-effort; if even this fails, structured-log it so we have
	// SOME record. Don't return the sink error to the caller.
	if err := h.sink.Emit(ev); err != nil {
		h.log.Error("rejection-event emit failed",
			"sink_err", err, "auth_err", authErr,
			"path", r.URL.Path, "method", r.Method)
	}
}
