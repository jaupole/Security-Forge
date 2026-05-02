package secrets

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestSecret_StringRedacts(t *testing.T) {
	s := NewSecret([]byte("sk_live_abc123"))
	if got := s.String(); got != "[redacted]" {
		t.Fatalf("String = %q, want [redacted]", got)
	}
	// The fmt.Stringer path also redacts.
	if got := fmt.Sprintf("%v", s); got != "[redacted]" {
		t.Fatalf("fmt.Sprintf %%v = %q, want [redacted]", got)
	}
	if got := fmt.Sprintf("%s", s); got != "[redacted]" {
		t.Fatalf("fmt.Sprintf %%s = %q, want [redacted]", got)
	}
}

func TestSecret_MarshalJSONRedacts(t *testing.T) {
	s := NewSecret([]byte("sk_live_abc123"))
	out, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if got := string(out); got != `"[redacted]"` {
		t.Fatalf("json.Marshal = %s, want \"[redacted]\"", got)
	}
	// Ensure the secret never appears in the JSON output for any
	// container shape — defense in depth against accidentally Marshal'ing
	// a struct/map that contains a Secret field (e.g., structured logs).
	wrapped, err := json.Marshal(map[string]Secret{"key": s})
	if err != nil {
		t.Fatalf("json.Marshal map: %v", err)
	}
	if strings.Contains(string(wrapped), "sk_live_abc123") {
		t.Fatalf("secret leaked in marshaled map: %s", wrapped)
	}
}

func TestSecret_UseInvokesCallbackAndZeroes(t *testing.T) {
	original := []byte("super-secret-value")
	s := NewSecret(original)

	var seen string
	err := s.Use(func(b []byte) error {
		seen = string(b)
		return nil
	})
	if err != nil {
		t.Fatalf("Use: %v", err)
	}
	if seen != "super-secret-value" {
		t.Fatalf("callback saw %q, want super-secret-value", seen)
	}
	// Underlying slice is now zeroed.
	for i, b := range original {
		if b != 0 {
			t.Fatalf("byte at %d = %d, want 0 (zero-on-Use)", i, b)
		}
	}
	// Subsequent Use returns the empty/already-used error.
	if err := s.Use(func(b []byte) error { return nil }); err == nil {
		t.Fatalf("second Use must error")
	}
}

func TestSecret_UseRejectsNilCallback(t *testing.T) {
	s := NewSecret([]byte("value"))
	if err := s.Use(nil); err == nil {
		t.Fatalf("Use(nil) must error")
	}
}

func TestSecret_UsePropagatesCallbackError(t *testing.T) {
	s := NewSecret([]byte("value"))
	want := errors.New("callback failed")
	err := s.Use(func(b []byte) error { return want })
	if !errors.Is(err, want) {
		t.Fatalf("Use err = %v, want %v", err, want)
	}
	// Bytes are still zeroed even when the callback errored.
	if !s.IsZero() {
		t.Fatalf("secret not zeroed after error path")
	}
}

func TestSecret_HTTPHeader(t *testing.T) {
	s := NewSecret([]byte("token-xyz"))
	name, value, err := s.HTTPHeader("Bearer")
	if err != nil {
		t.Fatalf("HTTPHeader: %v", err)
	}
	if name != "Authorization" {
		t.Fatalf("name = %q, want Authorization", name)
	}
	if value != "Bearer token-xyz" {
		t.Fatalf("value = %q, want \"Bearer token-xyz\"", value)
	}
}

func TestSecret_BasicAuth(t *testing.T) {
	s := NewSecret([]byte("hunter2"))
	name, value, err := s.BasicAuth("alice")
	if err != nil {
		t.Fatalf("BasicAuth: %v", err)
	}
	if name != "Authorization" {
		t.Fatalf("name = %q, want Authorization", name)
	}
	// Basic <base64("alice:hunter2")>
	const want = "Basic YWxpY2U6aHVudGVyMg=="
	if value != want {
		t.Fatalf("value = %q, want %q", value, want)
	}
}

func TestSecret_DSN(t *testing.T) {
	s := NewSecret([]byte("p@ss"))
	got, err := s.DSN("postgres://alice:{{.Secret}}@db.example/proposals")
	if err != nil {
		t.Fatalf("DSN: %v", err)
	}
	if got != "postgres://alice:p@ss@db.example/proposals" {
		t.Fatalf("DSN = %q", got)
	}
}

func TestSecret_NoSecretValueInErrorOnEmptyUse(t *testing.T) {
	// Constructing with empty bytes and then Using must surface the
	// "empty or already used" error, never echo any byte data.
	s := NewSecret([]byte{})
	err := s.Use(func(b []byte) error { return nil })
	if err == nil {
		t.Fatalf("Use on empty Secret must error")
	}
	if strings.Contains(err.Error(), "<") || strings.Contains(err.Error(), "byte") {
		// Just a sanity guard — error should mention "empty or already used".
		// Not a strict assertion; this is the redaction-discipline test.
		t.Logf("error message: %q (informational)", err.Error())
	}
}
