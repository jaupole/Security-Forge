package apiauth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testWorkload  = "spiffe://secforge.local/ns/app/sa/helloworld-bff"
	testUserSub   = "user-1"
	testTargetAud = "authzen-facade"
	testReqID     = "req-known-1"
)

func newTestAudit(buf *bytes.Buffer, opts ...func(*AuditConfig)) *Audit {
	cfg := AuditConfig{
		Writer: buf,
		Clock:  func() time.Time { return time.Date(2026, 5, 1, 12, 34, 56, 789_000_000, time.UTC) },
	}
	for _, o := range opts {
		o(&cfg)
	}
	return NewAudit(cfg)
}

func TestLogHop_AllSchemaFieldsPresentWithExpectedValues(t *testing.T) {
	var buf bytes.Buffer
	a := newTestAudit(&buf)
	req := httptest.NewRequest("GET", "https://api.test/orders?id=42", nil)
	req.Header.Set("X-Request-ID", testReqID)

	if err := a.LogHop(req, 1, testWorkload, testUserSub, testTargetAud, http.StatusOK); err != nil {
		t.Fatalf("LogHop: %v", err)
	}

	var out map[string]interface{}
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &out); err != nil {
		t.Fatalf("emitted line is not JSON: %v\n%s", err, buf.String())
	}
	expect := map[string]interface{}{
		"request_id":         testReqID,
		"hop_index":          float64(1),
		"caller_workload_id": testWorkload,
		"caller_user_sub":    testUserSub,
		"target_audience":    testTargetAud,
		"timestamp":          "2026-05-01T12:34:56.789Z",
		"endpoint":           "GET /orders",
		"status":             float64(200),
	}
	for k, v := range expect {
		if got := out[k]; got != v {
			t.Errorf("field %q: got %v want %v", k, got, v)
		}
	}
	// Endpoint deliberately omits query string.
	if strings.Contains(buf.String(), "id=42") {
		t.Errorf("query string leaked into audit line: %s", buf.String())
	}
}

func TestLogHop_FieldOrderFixed(t *testing.T) {
	var buf bytes.Buffer
	a := newTestAudit(&buf)
	req := httptest.NewRequest("POST", "https://api.test/x", nil)
	req.Header.Set("X-Request-ID", testReqID)

	if err := a.LogHop(req, 2, testWorkload, testUserSub, testTargetAud, http.StatusCreated); err != nil {
		t.Fatalf("LogHop: %v", err)
	}
	// Per ADR-0012 § Q4, the schema field order must be fixed. Regex over
	// the emitted line in declared order.
	want := regexp.MustCompile(
		`^\{"request_id":"[^"]+",` +
			`"hop_index":\d+,` +
			`"caller_workload_id":"[^"]+",` +
			`"caller_user_sub":"[^"]*",` +
			`"target_audience":"[^"]+",` +
			`"timestamp":"[^"]+",` +
			`"endpoint":"[A-Z]+ /[^"]*",` +
			`"status":\d+\}$`,
	)
	got := strings.TrimSpace(buf.String())
	if !want.MatchString(got) {
		t.Fatalf("emitted line did not match schema field order:\nGOT:  %s", got)
	}
}

func TestLogHop_GeneratesRequestIDIfAbsent(t *testing.T) {
	var buf bytes.Buffer
	a := newTestAudit(&buf)
	req := httptest.NewRequest("GET", "https://api.test/orders", nil)
	if got := req.Header.Get("X-Request-ID"); got != "" {
		t.Fatalf("precondition: X-Request-ID was not empty (%q)", got)
	}

	if err := a.LogHop(req, 0, testWorkload, testUserSub, testTargetAud, http.StatusOK); err != nil {
		t.Fatalf("LogHop: %v", err)
	}

	got := req.Header.Get("X-Request-ID")
	if got == "" {
		t.Fatalf("X-Request-ID was not written back to req.Header")
	}
	// Round-trip through emitted JSON to confirm same value.
	var line hopLine
	json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &line)
	if line.RequestID != got {
		t.Fatalf("emitted request_id (%q) != req.Header value (%q)", line.RequestID, got)
	}
	if len(got) < 16 {
		t.Fatalf("generated request_id too short: %q", got)
	}
}

func TestLogHop_PreservesIncomingRequestID(t *testing.T) {
	var buf bytes.Buffer
	a := newTestAudit(&buf)
	req := httptest.NewRequest("GET", "https://api.test/orders", nil)
	req.Header.Set("X-Request-ID", "custom-id-from-caller")
	if err := a.LogHop(req, 0, testWorkload, testUserSub, testTargetAud, http.StatusOK); err != nil {
		t.Fatalf("LogHop: %v", err)
	}
	if got := req.Header.Get("X-Request-ID"); got != "custom-id-from-caller" {
		t.Fatalf("incoming X-Request-ID overwritten: %q", got)
	}
	var line hopLine
	json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &line)
	if line.RequestID != "custom-id-from-caller" {
		t.Fatalf("emitted request_id was overwritten: %q", line.RequestID)
	}
}

// blockingWriter sleeps before returning a write — used to exercise the
// audit write-timeout path.
type blockingWriter struct {
	mu     sync.Mutex
	sleep  time.Duration
	wrote  []byte
	called int
}

func (b *blockingWriter) Write(p []byte) (int, error) {
	time.Sleep(b.sleep)
	b.mu.Lock()
	defer b.mu.Unlock()
	b.called++
	b.wrote = append(b.wrote, p...)
	return len(p), nil
}

func TestLogHop_SlowWriterDropsLineAndIncrementsCounter(t *testing.T) {
	bw := &blockingWriter{sleep: 200 * time.Millisecond}
	a := NewAudit(AuditConfig{
		Writer:       bw,
		Clock:        func() time.Time { return time.Date(2026, 5, 1, 12, 34, 56, 789_000_000, time.UTC) },
		WriteTimeout: 50 * time.Millisecond,
	})
	req := httptest.NewRequest("GET", "https://api.test/x", nil)
	req.Header.Set("X-Request-ID", testReqID)

	err := a.LogHop(req, 1, testWorkload, testUserSub, testTargetAud, http.StatusOK)
	if !errors.Is(err, ErrAuditTimeout) {
		t.Fatalf("got %v, want ErrAuditTimeout", err)
	}
	if got := a.Dropped(); got != 1 {
		t.Fatalf("dropped counter: got %d want 1", got)
	}
}

func TestLogHop_NilRequestReturnsErrorNotPanic(t *testing.T) {
	a := newTestAudit(&bytes.Buffer{})
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("LogHop panicked on nil req: %v", r)
		}
	}()
	if err := a.LogHop(nil, 0, "", "", "", 0); err == nil {
		t.Fatalf("expected error on nil request")
	}
}

func TestLogHop_DefaultsToStdoutTimeout100ms(t *testing.T) {
	// AuditConfig.WriteTimeout=0 → NewAudit sets it to defaultAuditWriteTimeout.
	a := NewAudit(AuditConfig{Writer: &bytes.Buffer{}})
	if a.cfg.WriteTimeout != defaultAuditWriteTimeout {
		t.Fatalf("default WriteTimeout: got %v want %v", a.cfg.WriteTimeout, defaultAuditWriteTimeout)
	}
}

func TestRequestIDContext(t *testing.T) {
	ctx := ContextWithRequestID(context.Background(), "abc-123")
	if got := RequestIDFromContext(ctx); got != "abc-123" {
		t.Fatalf("got %q want abc-123", got)
	}
	if got := RequestIDFromContext(context.Background()); got != "" {
		t.Fatalf("expected empty string for absent key, got %q", got)
	}
}
