package secrets

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeBao is a minimal OpenBao stand-in that responds to /v1/auth/jwt/login
// and KV-v2 read paths. Used to exercise the HTTP plumbing without the
// real OpenBao deployment.
type fakeBao struct {
	srv      *httptest.Server
	loginHit int
	kvHit    int
	wantRole string
	wantJWT  string
	kvData   map[string]map[string]string // path -> field -> value
	failNext bool                         // if true, next call returns 500
}

func newFakeBao(t *testing.T, role, expectedJWT string, kv map[string]map[string]string) *fakeBao {
	t.Helper()
	f := &fakeBao{wantRole: role, wantJWT: expectedJWT, kvData: kv}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/auth/jwt/login", func(w http.ResponseWriter, r *http.Request) {
		f.loginHit++
		if f.failNext {
			f.failNext = false
			http.Error(w, "transient", http.StatusInternalServerError)
			return
		}
		if r.Method != "POST" {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		var body struct{ Role, JWT string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Role != f.wantRole || body.JWT != f.wantJWT {
			http.Error(w, "bad role/jwt", http.StatusForbidden)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"auth": map[string]any{"client_token": "tok-test-12345"},
		})
	})
	mux.HandleFunc("/v1/", func(w http.ResponseWriter, r *http.Request) {
		f.kvHit++
		if r.Header.Get("X-Vault-Token") != "tok-test-12345" {
			http.Error(w, "bad token", http.StatusForbidden)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/v1/")
		fields, ok := f.kvData[path]
		if !ok {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{"data": fields},
		})
	})
	f.srv = httptest.NewServer(mux)
	return f
}

func (f *fakeBao) close() { f.srv.Close() }

// writeTempJWT writes a JWT-SVID-shaped string to a temp file and returns
// its path. The fake JWT doesn't have to actually parse — the real OpenBao
// would validate it; the fake here just compares the raw string.
func writeTempJWT(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "openbao.jwt")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write temp jwt: %v", err)
	}
	return p
}

// withTestHC swaps the bootstrapper's HTTP client for one whose default
// transport reaches localhost (the httptest.Server). Real BFF deployments
// use system roots; the test runs over plain HTTP from httptest.
func (b *OpenBaoBootstrapper) withTestHC(hc *http.Client) {
	b.hc = hc
}

func newTestBootstrapper(t *testing.T, srv *httptest.Server, jwtPath, role, kvPath string) *OpenBaoBootstrapper {
	t.Helper()
	b, err := NewOpenBaoBootstrapper(srv.URL, jwtPath, role, kvPath)
	if err != nil {
		t.Fatalf("NewOpenBaoBootstrapper: %v", err)
	}
	// Cast back so we can swap the HC. The interface doesn't expose this;
	// only the test code reaches into the concrete type.
	concrete := b.(*OpenBaoBootstrapper)
	concrete.withTestHC(srv.Client())
	return concrete
}

func TestGetClientKey_HappyPath(t *testing.T) {
	jwt := "fake-jwt-svid-bytes"
	// The test only checks byte-equality round-trip — the fixture
	// deliberately does NOT look like a real PEM (and avoids the
	// "BEGIN ... PRIVATE KEY" markers that trip pre-commit secret
	// scanners on test fixtures).
	kv := map[string]map[string]string{
		"secret/data/keycloak/clients/helloworld-bff": {
			"private_pem": "FIXTURE-not-a-real-pem-just-a-round-trip-check-1234",
		},
	}
	fake := newFakeBao(t, "helloworld-bff", jwt, kv)
	defer fake.close()
	jwtPath := writeTempJWT(t, jwt)
	b := newTestBootstrapper(t, fake.srv, jwtPath, "helloworld-bff", "secret/data/keycloak/clients/helloworld-bff")

	got, err := b.GetClientKey(context.Background())
	if err != nil {
		t.Fatalf("GetClientKey: %v", err)
	}
	want := kv["secret/data/keycloak/clients/helloworld-bff"]["private_pem"]
	if string(got) != want {
		t.Errorf("private_pem mismatch:\n got=%q\nwant=%q", got, want)
	}
	if fake.loginHit != 1 || fake.kvHit != 1 {
		t.Errorf("expected exactly 1 login + 1 kvRead; got login=%d kvRead=%d", fake.loginHit, fake.kvHit)
	}
}

func TestGetClientKey_FieldMissing(t *testing.T) {
	jwt := "fake-jwt"
	kv := map[string]map[string]string{
		"secret/data/keycloak/clients/helloworld-bff": {
			// no private_pem field — should produce a typed error
			"some-other-field": "bytes",
		},
	}
	fake := newFakeBao(t, "helloworld-bff", jwt, kv)
	defer fake.close()
	jwtPath := writeTempJWT(t, jwt)
	b := newTestBootstrapper(t, fake.srv, jwtPath, "helloworld-bff", "secret/data/keycloak/clients/helloworld-bff")

	if _, err := b.GetClientKey(context.Background()); err == nil {
		t.Errorf("expected error when private_pem field is missing; got nil")
	}
}

func TestGetClientKey_LoginRejected(t *testing.T) {
	// expected JWT differs from what we write — login returns 403
	fake := newFakeBao(t, "helloworld-bff", "expected-jwt", nil)
	defer fake.close()
	jwtPath := writeTempJWT(t, "different-jwt")
	b := newTestBootstrapper(t, fake.srv, jwtPath, "helloworld-bff", "secret/data/keycloak/clients/helloworld-bff")

	_, err := b.GetClientKey(context.Background())
	if err == nil || !strings.Contains(err.Error(), "openbao login") {
		t.Errorf("expected wrapped login error; got %v", err)
	}
}

func TestGetClientKey_NoSecretValueInError(t *testing.T) {
	// Sensitivity test: error messages must NOT include the secret value.
	jwt := "fake-jwt-svid-with-distinctive-suffix-DO_NOT_LEAK_ME"
	kv := map[string]map[string]string{
		"secret/data/keycloak/clients/helloworld-bff": {
			// No private_pem; error path triggers "field missing".
		},
	}
	fake := newFakeBao(t, "helloworld-bff", jwt, kv)
	defer fake.close()
	jwtPath := writeTempJWT(t, jwt)
	b := newTestBootstrapper(t, fake.srv, jwtPath, "helloworld-bff", "secret/data/keycloak/clients/helloworld-bff")

	_, err := b.GetClientKey(context.Background())
	if err == nil {
		t.Fatalf("expected error")
	}
	if strings.Contains(err.Error(), "DO_NOT_LEAK_ME") {
		t.Errorf("error message leaks JWT-SVID content: %q", err)
	}
}

func TestGetKV_HappyPath(t *testing.T) {
	jwt := "fake-jwt"
	kv := map[string]map[string]string{
		"secret/data/apps/foo/bar": {
			"alpha": "value-A",
			"beta":  "value-B",
		},
	}
	fake := newFakeBao(t, "test-role", jwt, kv)
	defer fake.close()
	jwtPath := writeTempJWT(t, jwt)
	b := newTestBootstrapper(t, fake.srv, jwtPath, "test-role", "secret/data/some/other/path")

	raw, err := b.GetKV(context.Background(), "secret/data/apps/foo/bar")
	if err != nil {
		t.Fatalf("GetKV: %v", err)
	}
	var r struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if r.Data.Data["alpha"] != "value-A" {
		t.Errorf("alpha mismatch: got %q want %q", r.Data.Data["alpha"], "value-A")
	}
}

func TestNewOpenBaoBootstrapper_RequiredArgs(t *testing.T) {
	cases := []struct {
		name             string
		addr, jwt, role  string
		kv               string
	}{
		{"no addr", "", "/tmp/jwt", "role", "secret/data/x"},
		{"no jwt", "https://x", "", "role", "secret/data/x"},
		{"no role", "https://x", "/tmp/jwt", "", "secret/data/x"},
		{"no kv", "https://x", "/tmp/jwt", "role", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := NewOpenBaoBootstrapper(c.addr, c.jwt, c.role, c.kv); err == nil {
				t.Errorf("expected error for %q; got nil", c.name)
			}
		})
	}
}
