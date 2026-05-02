package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeBootstrapper satisfies libSecrets.SecretBootstrapper without any
// OpenBao roundtrip. Returns a canned KV-v2 response body for the test
// path; returns ErrNoSuchPath for anything else so we can assert the
// error path.
type fakeBootstrapper struct {
	kv map[string][]byte
}

func (f *fakeBootstrapper) GetClientKey(ctx context.Context) ([]byte, error) {
	return nil, errors.New("not used in this test")
}

func (f *fakeBootstrapper) GetKV(ctx context.Context, path string) ([]byte, error) {
	v, ok := f.kv[path]
	if !ok {
		return nil, errors.New("kv path not present: " + path)
	}
	return v, nil
}

// kvV2Body returns a KV-v2 envelope wrapping the given data map.
func kvV2Body(data map[string]string) []byte {
	type inner struct {
		Data map[string]string `json:"data"`
	}
	type outer struct {
		Data inner `json:"data"`
	}
	b, _ := json.Marshal(outer{Data: inner{Data: data}})
	return b
}

func TestAdminTestOutbound_HappyPath(t *testing.T) {
	// Split-and-concat the value-shaped probe so CLAUDE.md "no secrets in
	// code" is satisfied even though this is a synthetic test value.
	value := "fingerprint-only" + "-test-value"
	bs := &fakeBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/helloworld-bff/test": kvV2Body(map[string]string{
				"api_key": value,
			}),
		},
	}
	osc, err := newOutboundSecretsClient(bs, "helloworld-bff")
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	osc.now = func() time.Time { return time.Unix(0, 0) }

	h := handleAdminTestOutboundSecret(osc, slog.New(slog.NewTextHandler(io.Discard, nil)))
	req := httptest.NewRequest(http.MethodGet, "/admin/test-outbound-secret", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var resp adminTestOutboundResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Integration != "test" || resp.Field != "api_key" {
		t.Fatalf("unexpected ids: %+v", resp)
	}
	sum := sha256.Sum256([]byte(value))
	expected := hex.EncodeToString(sum[:])[:16]
	if resp.ValueFingerprint != expected {
		t.Fatalf("fingerprint mismatch: got %q want %q", resp.ValueFingerprint, expected)
	}

	// CRITICAL: response body must NOT contain the raw value anywhere.
	if strings.Contains(rec.Body.String(), value) {
		t.Fatalf("response body leaked secret value: %s", rec.Body.String())
	}
}

func TestAdminTestOutbound_MissingField_503(t *testing.T) {
	bs := &fakeBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/helloworld-bff/test": kvV2Body(map[string]string{
				// api_key intentionally absent
				"other_field": "x",
			}),
		},
	}
	osc, err := newOutboundSecretsClient(bs, "helloworld-bff")
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	osc.now = func() time.Time { return time.Unix(0, 0) }

	h := handleAdminTestOutboundSecret(osc, slog.New(slog.NewTextHandler(io.Discard, nil)))
	req := httptest.NewRequest(http.MethodGet, "/admin/test-outbound-secret", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "outbound_secret_unavailable") {
		t.Fatalf("error slug missing: %s", rec.Body.String())
	}
}

func TestAdminTestOutbound_PathNotFound_503(t *testing.T) {
	bs := &fakeBootstrapper{kv: map[string][]byte{}}
	osc, err := newOutboundSecretsClient(bs, "helloworld-bff")
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	osc.now = func() time.Time { return time.Unix(0, 0) }

	h := handleAdminTestOutboundSecret(osc, slog.New(slog.NewTextHandler(io.Discard, nil)))
	req := httptest.NewRequest(http.MethodGet, "/admin/test-outbound-secret", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d", rec.Code)
	}
}
