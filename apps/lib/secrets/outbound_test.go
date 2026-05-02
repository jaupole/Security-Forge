package secrets

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeOutboundBootstrapper is an in-memory SecretBootstrapper for
// outbound Client tests. Maps OpenBao path → raw response bytes.
type fakeOutboundBootstrapper struct {
	kv      map[string][]byte
	getKVs  atomic.Int32
	failGet error
}

func (f *fakeOutboundBootstrapper) GetClientKey(ctx context.Context) ([]byte, error) {
	return nil, errors.New("not used by Client tests")
}

func (f *fakeOutboundBootstrapper) GetKV(ctx context.Context, path string) ([]byte, error) {
	f.getKVs.Add(1)
	if f.failGet != nil {
		return nil, f.failGet
	}
	v, ok := f.kv[path]
	if !ok {
		return nil, errors.New("path not found: " + path)
	}
	return v, nil
}

func TestNew_Validation(t *testing.T) {
	cases := []struct {
		name string
		bs   SecretBootstrapper
		cfg  Config
		ok   bool
	}{
		{name: "ok", bs: &fakeOutboundBootstrapper{}, cfg: Config{AppName: "a"}, ok: true},
		{name: "nil bootstrapper", bs: nil, cfg: Config{AppName: "a"}, ok: false},
		{name: "empty appname", bs: &fakeOutboundBootstrapper{}, cfg: Config{AppName: ""}, ok: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := New(c.bs, c.cfg)
			if c.ok && err != nil {
				t.Fatalf("New: %v", err)
			}
			if !c.ok && err == nil {
				t.Fatalf("New must error")
			}
		})
	}
}

func TestClient_GetField_HappyPath(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/proposal-forge/stripe": []byte(`{"data":{"data":{"api_key":"sk_live_xyz","webhook_secret":"whsec_aaa"}}}`),
		},
	}
	c, err := New(bs, Config{AppName: "proposal-forge", Hardened: true})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	sec, err := c.GetField(context.Background(), "stripe", "api_key")
	if err != nil {
		t.Fatalf("GetField: %v", err)
	}

	var seen string
	if err := sec.Use(func(b []byte) error { seen = string(b); return nil }); err != nil {
		t.Fatalf("Use: %v", err)
	}
	if seen != "sk_live_xyz" {
		t.Fatalf("seen = %q, want sk_live_xyz", seen)
	}
}

func TestClient_GetField_CacheHitSkipsBootstrapper(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/proposal-forge/openai": []byte(`{"data":{"data":{"api_key":"sk-aaa"}}}`),
		},
	}
	c, _ := New(bs, Config{AppName: "proposal-forge", CacheTTL: time.Minute})

	for i := 0; i < 5; i++ {
		sec, err := c.GetField(context.Background(), "openai", "api_key")
		if err != nil {
			t.Fatalf("iter %d: %v", i, err)
		}
		_ = sec.Use(func(b []byte) error { return nil })
	}
	// One miss + four hits → exactly one bootstrapper call.
	if got := bs.getKVs.Load(); got != 1 {
		t.Fatalf("bootstrapper invocations = %d, want 1 (cache should absorb the rest)", got)
	}
}

func TestClient_GetField_FieldMissing(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/proposal-forge/stripe": []byte(`{"data":{"data":{"api_key":"sk_live_xyz"}}}`),
		},
	}
	c, _ := New(bs, Config{AppName: "proposal-forge"})
	_, err := c.GetField(context.Background(), "stripe", "webhook_secret")
	if err == nil {
		t.Fatalf("missing field must error")
	}
	if strings.Contains(err.Error(), "sk_live_xyz") {
		t.Fatalf("error leaked secret value: %v", err)
	}
}

func TestClient_GetField_NoSecretValueInError(t *testing.T) {
	const leakCanary = "sk_live_CANARY_VALUE_DO_NOT_LEAK"
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/proposal-forge/stripe": []byte(`{"data":{"data":{"api_key":"` + leakCanary + `"}}}`),
		},
		// Make every GetKV fail AFTER successful lookup so the path
		// is exercised but the error path is what we assert against.
	}
	c, _ := New(bs, Config{AppName: "proposal-forge"})

	// Ask for a field that doesn't exist — error message must mention
	// the field name and integration but never the canary.
	_, err := c.GetField(context.Background(), "stripe", "nonexistent_field")
	if err == nil {
		t.Fatalf("expected error for missing field")
	}
	if strings.Contains(err.Error(), leakCanary) {
		t.Fatalf("error leaked secret canary: %v", err)
	}
}

func TestClient_GetField_BootstrapperError(t *testing.T) {
	bs := &fakeOutboundBootstrapper{failGet: errors.New("connection refused")}
	c, _ := New(bs, Config{AppName: "proposal-forge"})

	_, err := c.GetField(context.Background(), "stripe", "api_key")
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), "stripe") {
		t.Fatalf("error must include integration name: %v", err)
	}
}

func TestClient_GetField_BadJSON(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/proposal-forge/stripe": []byte(`<not json>`),
		},
	}
	c, _ := New(bs, Config{AppName: "proposal-forge"})

	_, err := c.GetField(context.Background(), "stripe", "api_key")
	if err == nil {
		t.Fatalf("expected decode error")
	}
}

func TestClient_GetField_EmptyArgs(t *testing.T) {
	bs := &fakeOutboundBootstrapper{}
	c, _ := New(bs, Config{AppName: "x"})

	if _, err := c.GetField(context.Background(), "", "field"); err == nil {
		t.Fatalf("empty integration must error")
	}
	if _, err := c.GetField(context.Background(), "intg", ""); err == nil {
		t.Fatalf("empty field must error")
	}
}

func TestClient_Close_ClearsCache(t *testing.T) {
	bs := &fakeOutboundBootstrapper{
		kv: map[string][]byte{
			"secret/data/apps/p/stripe": []byte(`{"data":{"data":{"api_key":"k"}}}`),
		},
	}
	c, _ := New(bs, Config{AppName: "p"})

	_, _ = c.GetField(context.Background(), "stripe", "api_key")
	if calls := bs.getKVs.Load(); calls != 1 {
		t.Fatalf("after first GetField, calls = %d, want 1", calls)
	}

	c.Close()
	_, _ = c.GetField(context.Background(), "stripe", "api_key")
	if calls := bs.getKVs.Load(); calls != 2 {
		t.Fatalf("after Close + GetField, calls = %d, want 2 (cache should've been cleared)", calls)
	}
}
