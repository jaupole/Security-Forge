package secrets

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// fakeTransit is a minimal OpenBao Transit stand-in that responds to
// /v1/auth/jwt/login, /v1/transit/encrypt/<key>, and
// /v1/transit/decrypt/<key>. Backing store is an in-memory ciphertext
// map; "encryption" is just base64 wrapping with a vault:v1: prefix so
// the test exercises the real ciphertext-format handling.
type fakeTransit struct {
	srv         *httptest.Server
	loginHits   atomic.Int32
	encryptHits atomic.Int32
	decryptHits atomic.Int32
	leaseSecs   int
	denyDecrypt bool
}

func newFakeTransit(t *testing.T) *fakeTransit {
	t.Helper()
	f := &fakeTransit{leaseSecs: 3600}
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/auth/jwt/login", func(w http.ResponseWriter, r *http.Request) {
		f.loginHits.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"auth": map[string]any{
				"client_token":   "tok-test-12345",
				"lease_duration": f.leaseSecs,
			},
		})
	})

	mux.HandleFunc("/v1/transit/encrypt/", func(w http.ResponseWriter, r *http.Request) {
		f.encryptHits.Add(1)
		if r.Header.Get("X-Vault-Token") != "tok-test-12345" {
			http.Error(w, "bad token", http.StatusForbidden)
			return
		}
		var body struct{ Plaintext string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		// Wrap in vault:v1: prefix; the body's already base64-encoded
		// per Transit's API so we just bolt on the prefix.
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"ciphertext": "vault:v1:" + body.Plaintext,
			},
		})
	})

	mux.HandleFunc("/v1/transit/decrypt/", func(w http.ResponseWriter, r *http.Request) {
		f.decryptHits.Add(1)
		if f.denyDecrypt {
			http.Error(w, "denied", http.StatusForbidden)
			return
		}
		if r.Header.Get("X-Vault-Token") != "tok-test-12345" {
			http.Error(w, "bad token", http.StatusForbidden)
			return
		}
		var body struct{ Ciphertext string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		ct := strings.TrimPrefix(body.Ciphertext, "vault:v1:")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{"plaintext": ct},
		})
	})

	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func writeJWT(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "jwt")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write jwt: %v", err)
	}
	return p
}

func TestTransit_EncryptThenDecrypt_Roundtrip(t *testing.T) {
	f := newFakeTransit(t)
	c, err := NewTransitClient(f.srv.URL, writeJWT(t, "fake-svid"), "myrole", "pii-encryption")
	if err != nil {
		t.Fatalf("NewTransitClient: %v", err)
	}
	ctx := context.Background()

	plain := []byte("alice@example.com")
	ct, err := c.Encrypt(ctx, plain)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.HasPrefix(ct, "vault:v1:") {
		t.Fatalf("Encrypt returned no vault:v1: prefix: %q", ct)
	}

	s, err := c.Decrypt(ctx, ct)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	var got []byte
	err = s.Use(func(b []byte) error {
		got = append(got[:0], b...)
		return nil
	})
	if err != nil {
		t.Fatalf("Use: %v", err)
	}
	if string(got) != string(plain) {
		t.Fatalf("roundtrip: want %q got %q", plain, got)
	}

	// One login (cached), one encrypt, one decrypt.
	if n := f.loginHits.Load(); n != 1 {
		t.Errorf("login hits: want 1 got %d (token cache not working)", n)
	}
}

func TestTransit_Encrypt_RejectsEmpty(t *testing.T) {
	f := newFakeTransit(t)
	c, _ := NewTransitClient(f.srv.URL, writeJWT(t, "x"), "r", "k")
	if _, err := c.Encrypt(context.Background(), nil); err == nil {
		t.Fatal("expected error on empty plaintext")
	}
}

func TestTransit_Decrypt_RejectsBadPrefix(t *testing.T) {
	f := newFakeTransit(t)
	c, _ := NewTransitClient(f.srv.URL, writeJWT(t, "x"), "r", "k")
	_, err := c.Decrypt(context.Background(), "not-a-vault-ciphertext")
	if err == nil {
		t.Fatal("expected error on missing vault:v<n>: prefix")
	}
	// Should NOT have hit the server (early-rejected).
	if n := f.decryptHits.Load(); n != 0 {
		t.Errorf("expected 0 decrypt server hits, got %d", n)
	}
}

func TestTransit_Decrypt_403_InvalidatesToken(t *testing.T) {
	f := newFakeTransit(t)
	c, _ := NewTransitClient(f.srv.URL, writeJWT(t, "x"), "r", "k")
	ctx := context.Background()

	// Prime the token cache via an Encrypt call.
	if _, err := c.Encrypt(ctx, []byte("seed")); err != nil {
		t.Fatalf("Encrypt seed: %v", err)
	}
	startingLogins := f.loginHits.Load()

	// Flip server to deny, attempt Decrypt — expect failure + cache eviction.
	f.denyDecrypt = true
	_, err := c.Decrypt(ctx, "vault:v1:"+base64.StdEncoding.EncodeToString([]byte("x")))
	if err == nil {
		t.Fatal("expected 403 error")
	}

	// Flip server back, confirm next call re-logs in (cache was invalidated).
	f.denyDecrypt = false
	if _, err := c.Encrypt(ctx, []byte("seed2")); err != nil {
		t.Fatalf("Encrypt after 403: %v", err)
	}
	if n := f.loginHits.Load(); n <= startingLogins {
		t.Errorf("expected fresh login after 403, got %d (started %d)", n, startingLogins)
	}
}

func TestNewTransitClient_RequiresAllArgs(t *testing.T) {
	cases := []struct{ addr, jwt, role, key string }{
		{"", "j", "r", "k"},
		{"a", "", "r", "k"},
		{"a", "j", "", "k"},
		{"a", "j", "r", ""},
	}
	for _, tc := range cases {
		_, err := NewTransitClient(tc.addr, tc.jwt, tc.role, tc.key)
		if err == nil {
			t.Errorf("expected error for case %+v", tc)
		}
	}
}
