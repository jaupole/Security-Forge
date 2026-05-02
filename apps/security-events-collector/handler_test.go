package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	apiauth "github.com/secforge/lib/api-auth"
)

// ─── Sink double ───────────────────────────────────────────────────────

type captureSink struct {
	mu     sync.Mutex
	events []Event
	fail   error
}

func (s *captureSink) Emit(e *Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail != nil {
		return s.fail
	}
	cp := *e
	s.events = append(s.events, cp)
	return nil
}

func (s *captureSink) snapshot() []Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Event, len(s.events))
	copy(out, s.events)
	return out
}

// ─── Validator double — satisfies the validator interface ──────────────
//
// The production wire is *apiauth.Middleware, which would require a JWKS
// server to construct in tests. Since handler.go depends on the narrow
// validator interface, we can substitute this fake without spinning up
// any JWKS plumbing.

type fakeMW struct {
	claims *apiauth.Claims
	err    error
}

func (f *fakeMW) ValidateInbound(*http.Request) (*apiauth.Claims, error) {
	return f.claims, f.err
}

// ─── Helpers ───────────────────────────────────────────────────────────

func discardLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func fixedClock(s string) func() time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return func() time.Time { return t }
}

func newTestHandler(v validator, sink Sink) *handler {
	return &handler{
		mw:   v,
		sink: sink,
		log:  discardLog(),
		now:  fixedClock("2026-05-02T14:00:00Z"),
	}
}

func goodEvent() Event {
	return Event{
		Timestamp: "2026-05-02T14:00:00Z",
		EventName: EventNameBypass,
		Layer:     LayerKyverno,
		Severity:  SeverityHigh,
		Actor:     "ATTACKER-CLAIMED-IDENTITY",
		Resource:  "Pod/app/proposal-forge-abc",
		Rule:      "no-secret-shaped-env-vars",
		Outcome:   OutcomeBlocked,
	}
}

func postEvent(t *testing.T, h http.Handler, ev Event, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/secrets/guardrail/bypass",
		bytes.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// ─── Tests ─────────────────────────────────────────────────────────────

func TestHandler_OverridesActorWithSPIFFEID(t *testing.T) {
	t.Parallel()
	spiffe := "spiffe://secforge.local/ns/kyverno/sa/admission-controller"
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{SPIFFEID: &spiffe, Sub: "irrelevant"}}, sink)

	rec := postEvent(t, h, goodEvent(), nil)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d body=%s", rec.Code, rec.Body.String())
	}
	got := sink.snapshot()
	if len(got) != 1 {
		t.Fatalf("want 1 event, got %d", len(got))
	}
	if got[0].Actor != spiffe {
		t.Fatalf("actor not overridden: got %q", got[0].Actor)
	}
}

func TestHandler_FallsBackToOIDCSub(t *testing.T) {
	t.Parallel()
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "ci-runner-7"}}, sink)

	rec := postEvent(t, h, goodEvent(), nil)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	got := sink.snapshot()[0]
	if got.Actor != "kc:ci-runner-7" {
		t.Fatalf("want kc:ci-runner-7, got %q", got.Actor)
	}
}

func TestHandler_RejectionEmitsEvent(t *testing.T) {
	t.Parallel()
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{err: apiauth.ErrInvalidToken}, sink)

	rec := postEvent(t, h, goodEvent(), map[string]string{"X-Request-Id": "req-42"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
	got := sink.snapshot()
	if len(got) != 1 {
		t.Fatalf("want 1 rejection event, got %d", len(got))
	}
	if got[0].Actor != "unauthenticated" {
		t.Fatalf("actor=%q, want unauthenticated", got[0].Actor)
	}
	if got[0].Severity != SeverityHigh {
		t.Fatalf("severity=%q, want high", got[0].Severity)
	}
	if got[0].Outcome != OutcomeBlocked {
		t.Fatalf("outcome=%q, want blocked", got[0].Outcome)
	}
	if got[0].RequestID != "req-42" {
		t.Fatalf("request_id=%q, want req-42", got[0].RequestID)
	}
}

func TestHandler_RejectsInvalidJSON(t *testing.T) {
	t.Parallel()
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "x"}}, sink)
	req := httptest.NewRequest(http.MethodPost, "/v1/secrets/guardrail/bypass",
		strings.NewReader("not json"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
	if len(sink.snapshot()) != 0 {
		t.Fatal("invalid JSON should not have emitted to sink")
	}
}

func TestHandler_RejectsInvalidEventSchema(t *testing.T) {
	t.Parallel()
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "x"}}, sink)
	bad := goodEvent()
	bad.Layer = "made-up"
	rec := postEvent(t, h, bad, nil)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
}

func TestHandler_FillsTimestampWhenMissing(t *testing.T) {
	t.Parallel()
	sink := &captureSink{}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "x"}}, sink)
	ev := goodEvent()
	ev.Timestamp = ""
	rec := postEvent(t, h, ev, nil)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	got := sink.snapshot()[0]
	if got.Timestamp != "2026-05-02T14:00:00Z" {
		t.Fatalf("timestamp not filled: %q", got.Timestamp)
	}
}

func TestHandler_500OnSinkFailure(t *testing.T) {
	t.Parallel()
	sink := &captureSink{fail: errors.New("disk full")}
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "x"}}, sink)
	rec := postEvent(t, h, goodEvent(), nil)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("want 500, got %d", rec.Code)
	}
}

func TestHandler_RejectsNonPOST(t *testing.T) {
	t.Parallel()
	h := newTestHandler(&fakeMW{claims: &apiauth.Claims{Sub: "x"}}, &captureSink{})
	req := httptest.NewRequest(http.MethodGet, "/v1/secrets/guardrail/bypass", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", rec.Code)
	}
}

func TestVerifiedActor(t *testing.T) {
	t.Parallel()
	spiffe := "spiffe://secforge.local/ns/x/sa/y"

	cases := []struct {
		name string
		in   *apiauth.Claims
		want string
	}{
		{"nil_claims", nil, "unknown"},
		{"spiffe_only", &apiauth.Claims{SPIFFEID: &spiffe}, spiffe},
		{"spiffe_wins_over_sub", &apiauth.Claims{SPIFFEID: &spiffe, Sub: "alice"}, spiffe},
		{"sub_fallback", &apiauth.Claims{Sub: "alice"}, "kc:alice"},
		{"empty_spiffe_falls_back", &apiauth.Claims{SPIFFEID: ptrToStr(""), Sub: "alice"}, "kc:alice"},
		{"both_empty", &apiauth.Claims{}, "unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := verifiedActor(tc.in); got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func ptrToStr(s string) *string { return &s }

// Compile-time check: apiauth.Middleware satisfies the validator
// interface so the production wire and test fake share the same contract.
var _ validator = (*apiauth.Middleware)(nil)
