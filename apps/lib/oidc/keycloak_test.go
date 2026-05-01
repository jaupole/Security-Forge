package oidc

import (
	"context"
	"crypto"
	_ "crypto/sha256" // register sha256 for crypto.SHA256
	"crypto/rand"
	"crypto/rsa"
	cryptosha256 "crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

// TestKidFor verifies the Keycloak-specific kid derivation. Deterministic:
// base64url(SHA-256(DER-PKIX)). The test exists primarily as a regression
// guard — if this changes, all platform Keycloak clients need re-registration.
func TestKidFor(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshal pubkey DER: %v", err)
	}
	expectedSum := cryptosha256.Sum256(der)
	expected := base64.RawURLEncoding.EncodeToString(expectedSum[:])

	// We need a Provider instance; KidFor doesn't depend on issuer/JWKS
	// state so we can call it on a struct without going through the
	// constructor. The test verifies the contract, not the constructor.
	p := &KeycloakProvider{}
	got := p.KidFor(der)
	if got != expected {
		t.Errorf("kid mismatch:\n  got=%q\n  want=%q", got, expected)
	}
	// Defense-in-depth: ensure it's NOT the RFC 7638 JWK thumbprint
	// (which would be a different, longer base64 over canonical JWK
	// JSON). The RFC 7638 path would produce a different value; equal
	// here would mean someone "fixed" KidFor to RFC 7638 and broke the
	// Keycloak integration. We compute the RFC 7638 thumbprint via jwk
	// for a real comparison and assert non-equality.
	jwkKey, err := jwk.FromRaw(&priv.PublicKey)
	if err != nil {
		t.Fatalf("jwk.FromRaw: %v", err)
	}
	rfc7638, err := jwkKey.Thumbprint(crypto.SHA256)
	if err != nil {
		t.Fatalf("rfc7638 thumbprint: %v", err)
	}
	rfc7638Str := base64.RawURLEncoding.EncodeToString(rfc7638)
	if got == rfc7638Str {
		t.Errorf("KidFor produced RFC 7638 thumbprint %q — this is the bug Keycloak rejects with 'PublicKey wasn't found'", got)
	}
}

// TestParseIDToken does an end-to-end happy-path: spin up a fake issuer
// (httptest.Server) hosting OIDC discovery + JWKS, mint a token signed
// with the test key, call ParseIDToken, assert Claims fields. This is
// closer to integration than unit, but it's the only way to exercise the
// real go-oidc verifier path without mocking the verifier itself (which
// would defeat the test's purpose).
func TestParseIDToken(t *testing.T) {
	// Generate an issuer signing key.
	issuerKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate issuer key: %v", err)
	}
	jwkKey, err := jwk.FromRaw(&issuerKey.PublicKey)
	if err != nil {
		t.Fatalf("jwk.FromRaw: %v", err)
	}
	if err := jwkKey.Set(jwk.KeyIDKey, "test-key-1"); err != nil {
		t.Fatalf("set kid: %v", err)
	}
	if err := jwkKey.Set(jwk.AlgorithmKey, jwa.RS256); err != nil {
		t.Fatalf("set alg: %v", err)
	}

	// Spin up the fake issuer.
	mux := http.NewServeMux()
	var issuerURL string

	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                issuerURL,
			"authorization_endpoint":                issuerURL + "/auth",
			"token_endpoint":                        issuerURL + "/token",
			"jwks_uri":                              issuerURL + "/jwks",
			"response_types_supported":              []string{"code"},
			"subject_types_supported":               []string{"public"},
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, r *http.Request) {
		set := jwk.NewSet()
		_ = set.AddKey(jwkKey)
		w.Header().Set("Content-Type", "application/json")
		buf, _ := json.Marshal(set)
		_, _ = w.Write(buf)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	issuerURL = srv.URL

	// Construct the Provider against the fake issuer.
	prov, err := NewKeycloakProvider(context.Background(), issuerURL, "test-client", srv.Client())
	if err != nil {
		t.Fatalf("NewKeycloakProvider: %v", err)
	}

	// Mint a fixture token signed by the test key, in Keycloak shape.
	now := time.Now()
	tok := jwt.New()
	_ = tok.Set(jwt.IssuerKey, issuerURL)
	_ = tok.Set(jwt.SubjectKey, "user-42")
	_ = tok.Set(jwt.AudienceKey, "test-client")
	_ = tok.Set(jwt.IssuedAtKey, now)
	_ = tok.Set(jwt.ExpirationKey, now.Add(5*time.Minute))
	_ = tok.Set("preferred_username", "alice")
	_ = tok.Set("email", "alice@example.test")
	_ = tok.Set("session_state", "abc-session-state")
	_ = tok.Set("nonce", "n-1234567890")
	_ = tok.Set("realm_access", map[string]any{
		"roles": []string{"platform_admin", "tenant_user"},
	})

	hdrs := jws.NewHeaders()
	_ = hdrs.Set(jws.KeyIDKey, "test-key-1")
	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256, issuerKey, jws.WithProtectedHeaders(hdrs)))
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}

	// Exercise ParseIDToken.
	claims, err := prov.ParseIDToken(context.Background(), string(signed))
	if err != nil {
		t.Fatalf("ParseIDToken: %v", err)
	}

	if claims.Subject != "user-42" {
		t.Errorf("Subject: got %q want %q", claims.Subject, "user-42")
	}
	if claims.PreferredUsername != "alice" {
		t.Errorf("PreferredUsername: got %q want %q", claims.PreferredUsername, "alice")
	}
	if claims.Email != "alice@example.test" {
		t.Errorf("Email: got %q want %q", claims.Email, "alice@example.test")
	}
	if claims.SessionState != "abc-session-state" {
		t.Errorf("SessionState: got %q want %q", claims.SessionState, "abc-session-state")
	}
	if claims.Nonce != "n-1234567890" {
		t.Errorf("Nonce: got %q want %q", claims.Nonce, "n-1234567890")
	}
	if len(claims.Roles) != 2 || claims.Roles[0] != "platform_admin" || claims.Roles[1] != "tenant_user" {
		t.Errorf("Roles: got %v want [platform_admin tenant_user]", claims.Roles)
	}
	if _, ok := claims.Raw["sub"]; !ok {
		t.Errorf("Raw escape hatch missing — expected 'sub' in Raw map; got keys %v", keysOf(claims.Raw))
	}
}

// TestParseIDToken_ExpiredRejected confirms the verifier path actually
// validates exp — a regression here would silently accept stale tokens.
func TestParseIDToken_ExpiredRejected(t *testing.T) {
	issuerKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	jwkKey, _ := jwk.FromRaw(&issuerKey.PublicKey)
	_ = jwkKey.Set(jwk.KeyIDKey, "test-key-1")
	_ = jwkKey.Set(jwk.AlgorithmKey, jwa.RS256)

	var issuerURL string
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                issuerURL,
			"jwks_uri":                              issuerURL + "/jwks",
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, r *http.Request) {
		set := jwk.NewSet()
		_ = set.AddKey(jwkKey)
		buf, _ := json.Marshal(set)
		_, _ = w.Write(buf)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	issuerURL = srv.URL

	prov, err := NewKeycloakProvider(context.Background(), issuerURL, "test-client", srv.Client())
	if err != nil {
		t.Fatalf("NewKeycloakProvider: %v", err)
	}

	// Mint an EXPIRED token.
	tok := jwt.New()
	_ = tok.Set(jwt.IssuerKey, issuerURL)
	_ = tok.Set(jwt.SubjectKey, "user-42")
	_ = tok.Set(jwt.AudienceKey, "test-client")
	_ = tok.Set(jwt.IssuedAtKey, time.Now().Add(-2*time.Hour))
	_ = tok.Set(jwt.ExpirationKey, time.Now().Add(-1*time.Hour))
	hdrs := jws.NewHeaders()
	_ = hdrs.Set(jws.KeyIDKey, "test-key-1")
	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256, issuerKey, jws.WithProtectedHeaders(hdrs)))
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}

	if _, err := prov.ParseIDToken(context.Background(), string(signed)); err == nil {
		t.Errorf("expected ParseIDToken to reject expired token; got nil error")
	}
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
