package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestGetenv(t *testing.T) {
	t.Setenv("FOO", "bar")
	if got := getenv("FOO", "def"); got != "bar" {
		t.Fatalf("set: got %q", got)
	}
	if got := getenv("UNSET_KEY_XYZ", "def"); got != "def" {
		t.Fatalf("unset: got %q", got)
	}
}

func TestLoadCfg(t *testing.T) {
	t.Setenv("COLLECTOR_ISSUER", "https://kc.local/realms/x")
	t.Setenv("COLLECTOR_AUDIENCE", "security-events-collector")
	t.Setenv("COLLECTOR_JWKS_ENDPOINT", "https://kc.local/realms/x/protocol/openid-connect/certs")
	t.Setenv("COLLECTOR_WORKLOAD_ID", "spiffe://secforge.local/ns/security/sa/collector")

	c, err := loadCfg()
	if err != nil {
		t.Fatalf("loadCfg: %v", err)
	}
	if c.ListenAddr != ":8080" {
		t.Fatalf("default listen: %q", c.ListenAddr)
	}
	if c.Issuer != "https://kc.local/realms/x" {
		t.Fatalf("issuer: %q", c.Issuer)
	}
	if c.Audience != "security-events-collector" {
		t.Fatalf("audience: %q", c.Audience)
	}
	if c.ShutdownGrace != 15*time.Second {
		t.Fatalf("shutdown grace: %v", c.ShutdownGrace)
	}
}

func TestHandleHealthz(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handleHealthz(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	if rec.Header().Get("Content-Type") != "application/json" {
		t.Fatal("missing JSON content-type")
	}
}

func TestNoopReplayCache(t *testing.T) {
	t.Parallel()
	c := noopReplayCache{}
	seen, err := c.SeenWithin(context.Background(), "any-jti", time.Minute)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if seen {
		t.Fatal("noop should never report seen")
	}
}
