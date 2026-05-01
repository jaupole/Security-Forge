package apiauth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

// --- in-memory SessionStore used only by tests --------------------------

type memSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*SessionTokens
}

func newMemSessionStore() *memSessionStore {
	return &memSessionStore{sessions: map[string]*SessionTokens{}}
}

func (m *memSessionStore) GetSession(ctx context.Context, key string) (*SessionTokens, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[key]
	if !ok {
		return nil, nil
	}
	cp := *s
	return &cp, nil
}

func (m *memSessionStore) PutSession(ctx context.Context, key string, t *SessionTokens) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cp := *t
	m.sessions[key] = &cp
	return nil
}

// --- client test rig -----------------------------------------------------

type clientRig struct {
	t            *testing.T
	store        *memSessionStore
	dpopKey      *ecdsa.PrivateKey
	clientRSAKey *rsa.PrivateKey
	clientPEM    []byte
	signKey      *rsa.PrivateKey // simulates Keycloak's signing key
	signJWK      jwk.Key
	tokenSrv     *httptest.Server
	tokenHits    int64
	clientObj    *Client
	now          func() time.Time

	// scriptable fake-Keycloak behavior
	respBody  []byte
	respCode  int
	gotForm   url.Values
	gotDPoP   string
	gotAuth   string
	transport func(req *http.Request) // optional capture/inspection
}

func newClientRig(t *testing.T) *clientRig {
	t.Helper()
	cr := &clientRig{
		t:        t,
		store:    newMemSessionStore(),
		respCode: http.StatusOK,
	}
	cr.now = func() time.Time { return time.Unix(1_700_000_000, 0).UTC() }

	dpopKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ecdsa: %v", err)
	}
	cr.dpopKey = dpopKey

	clientRSA, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa client: %v", err)
	}
	cr.clientRSAKey = clientRSA
	clientPKCS8, err := x509.MarshalPKCS8PrivateKey(clientRSA)
	if err != nil {
		t.Fatalf("pkcs8: %v", err)
	}
	cr.clientPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: clientPKCS8})

	signKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa sign: %v", err)
	}
	cr.signKey = signKey
	signJWK, _ := jwk.FromRaw(signKey.Public())
	signJWK.Set(jwk.KeyIDKey, "sign-1")
	signJWK.Set(jwk.AlgorithmKey, jwa.RS256)
	cr.signJWK = signJWK

	cr.tokenSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&cr.tokenHits, 1)
		_ = r.ParseForm()
		cr.gotForm = r.PostForm
		cr.gotDPoP = r.Header.Get("DPoP")
		cr.gotAuth = r.Header.Get("Authorization")
		if cr.transport != nil {
			cr.transport(r)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(cr.respCode)
		w.Write(cr.respBody)
	}))
	t.Cleanup(cr.tokenSrv.Close)

	cr.clientObj = NewClient(ClientConfig{
		TokenEndpoint:      cr.tokenSrv.URL,
		ClientID:           "helloworld-bff",
		ClientAssertionPEM: cr.clientPEM,
		AudienceList:       []string{"authzen-facade", "helloworld-api"},
		SessionStore:       cr.store,
		DPoPKey:            cr.dpopKey,
		HTTPClient:         cr.tokenSrv.Client(),
		Clock:              cr.now,
	})
	return cr
}

// mintIssuedAccessToken signs an access token with cr.signKey for the
// fake-Keycloak response body.
func (cr *clientRig) mintIssuedAccessToken(aud []string, jktB64 string) string {
	cr.t.Helper()
	tok := jwt.New()
	tok.Set(jwt.IssuerKey, "https://keycloak.test/realms/secforge")
	tok.Set(jwt.AudienceKey, aud)
	tok.Set(jwt.SubjectKey, "user-1")
	tok.Set(jwt.IssuedAtKey, cr.now())
	tok.Set(jwt.ExpirationKey, cr.now().Add(1*time.Hour))
	if jktB64 != "" {
		tok.Set("cnf", map[string]interface{}{"jkt": jktB64})
	}
	hdr := jws.NewHeaders()
	hdr.Set(jws.KeyIDKey, "sign-1")
	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256, cr.signKey, jws.WithProtectedHeaders(hdr)))
	if err != nil {
		cr.t.Fatalf("sign: %v", err)
	}
	return string(signed)
}

func (cr *clientRig) dpopThumbprint() string {
	pubJWK, _ := jwk.PublicKeyOf(cr.dpopKey)
	tp, _ := pubJWK.Thumbprint(crypto.SHA256)
	return base64.RawURLEncoding.EncodeToString(tp)
}

// =========================================================================
// Tests
// =========================================================================

func TestMint_AudienceNotConfigured(t *testing.T) {
	cr := newClientRig(t)
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "not-in-list")
	if !errors.Is(err, ErrAudienceNotConfigured) {
		t.Fatalf("got %v, want ErrAudienceNotConfigured", err)
	}
	if got := atomic.LoadInt64(&cr.tokenHits); got != 0 {
		t.Fatalf("Keycloak should not be contacted, got %d hits", got)
	}
}

func TestMint_NoSessionInContext(t *testing.T) {
	cr := newClientRig(t)
	_, err := cr.clientObj.MintTokenForAudience(context.Background(), "authzen-facade")
	if !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("got %v, want ErrInvalidToken", err)
	}
}

func TestMint_SessionAbsent(t *testing.T) {
	cr := newClientRig(t)
	ctx := ContextWithSessionKey(context.Background(), "sess-missing")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if !errors.Is(err, ErrAudienceUnavailable) {
		t.Fatalf("got %v, want ErrAudienceUnavailable", err)
	}
}

func TestMint_CacheHitNoKeycloakCall(t *testing.T) {
	cr := newClientRig(t)
	jkt := cr.dpopThumbprint()
	cached := cr.mintIssuedAccessToken([]string{"authzen-facade"}, jkt)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		AccessToken:  cached,
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(30 * time.Minute),
		Audiences:    []string{"authzen-facade"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	tok, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if err != nil {
		t.Fatalf("cache hit: %v", err)
	}
	if tok != cached {
		t.Fatalf("expected cached token, got different value")
	}
	if got := atomic.LoadInt64(&cr.tokenHits); got != 0 {
		t.Fatalf("Keycloak should not be contacted on cache hit, got %d hits", got)
	}
}

func TestMint_RefreshSucceeds(t *testing.T) {
	cr := newClientRig(t)
	jkt := cr.dpopThumbprint()
	newTok := cr.mintIssuedAccessToken([]string{"authzen-facade"}, jkt)
	cr.respBody = []byte(`{"access_token":"` + newTok + `","refresh_token":"ref-2","expires_in":3600}`)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		AccessToken:  "stale",
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(-1 * time.Minute),
		Audiences:    []string{"openid"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	tok, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if err != nil {
		t.Fatalf("refresh succeeds: %v", err)
	}
	if tok != newTok {
		t.Fatalf("expected new token")
	}
	if got := atomic.LoadInt64(&cr.tokenHits); got != 1 {
		t.Fatalf("expected exactly one Keycloak hit, got %d", got)
	}
	// Form-data inspection: scope expanded with the requested aud.
	scope := cr.gotForm.Get("scope")
	if !strings.Contains(scope, "authzen-facade") {
		t.Fatalf("scope should include audience, got %q", scope)
	}
	if cr.gotForm.Get("grant_type") != "refresh_token" {
		t.Fatalf("grant_type=%q want refresh_token", cr.gotForm.Get("grant_type"))
	}
	if cr.gotForm.Get("client_assertion_type") != "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" {
		t.Fatalf("client_assertion_type missing")
	}
	if cr.gotForm.Get("client_assertion") == "" {
		t.Fatalf("client_assertion missing")
	}
	if cr.gotDPoP == "" {
		t.Fatalf("DPoP header missing on refresh")
	}
	// Persistence: cache updated.
	stored, _ := cr.store.GetSession(context.Background(), "sess-1")
	if stored.AccessToken != newTok {
		t.Fatalf("session not updated")
	}
}

func TestMint_RefreshInvalidScope(t *testing.T) {
	cr := newClientRig(t)
	cr.respCode = http.StatusBadRequest
	cr.respBody = []byte(`{"error":"invalid_scope","error_description":"unknown audience"}`)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		AccessToken:  "stale",
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(-1 * time.Minute),
		Audiences:    []string{"openid"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if !errors.Is(err, ErrAudienceUnavailable) {
		t.Fatalf("got %v, want ErrAudienceUnavailable", err)
	}
}

func TestMint_RefreshInvalidGrant(t *testing.T) {
	cr := newClientRig(t)
	cr.respCode = http.StatusBadRequest
	cr.respBody = []byte(`{"error":"invalid_grant"}`)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(-1 * time.Minute),
		Audiences:    []string{"openid"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if !errors.Is(err, ErrAudienceUnavailable) {
		t.Fatalf("got %v, want ErrAudienceUnavailable", err)
	}
}

func TestMint_Refresh5xxReturnsKeycloakUnreachable(t *testing.T) {
	cr := newClientRig(t)
	cr.respCode = http.StatusBadGateway
	cr.respBody = []byte(`upstream`)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(-1 * time.Minute),
		Audiences:    []string{"openid"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if !errors.Is(err, ErrKeycloakUnreachable) {
		t.Fatalf("got %v, want ErrKeycloakUnreachable", err)
	}
}

func TestMint_RefreshDoesNotIncludeAudienceInResultingToken(t *testing.T) {
	// Defense-in-depth: even on a 200 response, if Keycloak somehow returns
	// a token whose aud doesn't include the requested value, library refuses.
	cr := newClientRig(t)
	bogusTok := cr.mintIssuedAccessToken([]string{"openid"}, cr.dpopThumbprint())
	cr.respBody = []byte(`{"access_token":"` + bogusTok + `","refresh_token":"r2","expires_in":3600}`)
	cr.store.PutSession(context.Background(), "sess-1", &SessionTokens{
		RefreshToken: "ref-1",
		ExpiresAt:    cr.now().Add(-1 * time.Minute),
		Audiences:    []string{"openid"},
	})
	ctx := ContextWithSessionKey(context.Background(), "sess-1")
	_, err := cr.clientObj.MintTokenForAudience(ctx, "authzen-facade")
	if !errors.Is(err, ErrAudienceUnavailable) {
		t.Fatalf("got %v, want ErrAudienceUnavailable", err)
	}
}

func TestDPoPKeyThumbprint_Stable(t *testing.T) {
	cr := newClientRig(t)
	a, err := cr.clientObj.DPoPKeyThumbprint()
	if err != nil {
		t.Fatalf("thumbprint: %v", err)
	}
	b := cr.dpopThumbprint()
	if a != b {
		t.Fatalf("thumbprint mismatch: %s vs %s", a, b)
	}
}

func TestSessionKeyContext(t *testing.T) {
	ctx := ContextWithSessionKey(context.Background(), "abc")
	if got := SessionKeyFromContext(ctx); got != "abc" {
		t.Fatalf("got %q want abc", got)
	}
	if got := SessionKeyFromContext(context.Background()); got != "" {
		t.Fatalf("expected empty string for absent key, got %q", got)
	}
}

func TestExpandScopeKeepsExistingAndAppendsAudience(t *testing.T) {
	got := expandScope([]string{"openid", "profile", "email", "groups"}, "authzen-facade")
	want := "openid profile email groups authzen-facade"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestExpandScopeDoesNotDuplicateAudienceAlreadyInScope(t *testing.T) {
	got := expandScope([]string{"openid", "authzen-facade"}, "authzen-facade")
	want := "openid profile email authzen-facade"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

// Smoke-test that the JWS produced by makeClientAssertion is parseable JWS
// signed by the configured client_assertion key.
func TestClientAssertionShape(t *testing.T) {
	cr := newClientRig(t)
	a, err := cr.clientObj.makeClientAssertion()
	if err != nil {
		t.Fatalf("makeClientAssertion: %v", err)
	}
	pub := cr.clientRSAKey.Public()
	pubJWK, _ := jwk.FromRaw(pub)
	pubJWK.Set(jwk.AlgorithmKey, jwa.RS256)
	// Skip validation — the rig clock is set to 2023 so any real-time
	// parser would fail exp; we just want the signature to verify.
	parsed, err := jwt.Parse([]byte(a), jwt.WithKey(jwa.RS256, pubJWK), jwt.WithValidate(false))
	if err != nil {
		t.Fatalf("client_assertion did not verify: %v", err)
	}
	if parsed.Issuer() != "helloworld-bff" {
		t.Fatalf("iss=%q want helloworld-bff", parsed.Issuer())
	}
	if !audContains(parsed.Audience(), cr.tokenSrv.URL) {
		t.Fatalf("aud should include token endpoint URL")
	}
}

// Smoke-test that the DPoP proof is parseable JWS and carries the right
// htm/htu/iat/jti shape.
func TestDPoPProofShape(t *testing.T) {
	cr := newClientRig(t)
	proof, err := cr.clientObj.makeDPoPProof("POST", cr.tokenSrv.URL)
	if err != nil {
		t.Fatalf("makeDPoPProof: %v", err)
	}
	msg, err := jws.Parse([]byte(proof))
	if err != nil {
		t.Fatalf("parse dpop: %v", err)
	}
	embeddedJWK := msg.Signatures()[0].ProtectedHeaders().JWK()
	if embeddedJWK == nil {
		t.Fatalf("dpop missing embedded jwk")
	}
	payload, err := jws.Verify([]byte(proof), jws.WithKey(jwa.ES256, embeddedJWK))
	if err != nil {
		t.Fatalf("verify dpop: %v", err)
	}
	var p struct {
		HTM string `json:"htm"`
		HTU string `json:"htu"`
		IAT int64  `json:"iat"`
		JTI string `json:"jti"`
	}
	if err := json.Unmarshal(payload, &p); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if p.HTM != "POST" || p.HTU != cr.tokenSrv.URL || p.JTI == "" || p.IAT == 0 {
		t.Fatalf("dpop fields wrong: %+v", p)
	}
}
