package apiauth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
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

const (
	testIssuer   = "https://keycloak.test/realms/secforge"
	testAudience = "https://api.test"
	testKID      = "test-rsa-1"
)

// --- in-memory ReplayCache used only by tests ----------------------------

type memReplayCache struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func newMemReplayCache() *memReplayCache {
	return &memReplayCache{seen: map[string]time.Time{}}
}

func (c *memReplayCache) SeenWithin(ctx context.Context, jti string, window time.Duration) (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	if t, ok := c.seen[jti]; ok && now.Sub(t) < window {
		return true, nil
	}
	c.seen[jti] = now
	return false, nil
}

// --- test rig ------------------------------------------------------------

type testRig struct {
	t          *testing.T
	rsaKey     *rsa.PrivateKey
	rsaJWKS    jwk.Set
	jwksHits   int64
	jwksServer *httptest.Server

	dpopKey *ecdsa.PrivateKey
	dpopJWK jwk.Key
	jktB64  string

	cache *memReplayCache
	mw    *Middleware
}

func newRig(t *testing.T) *testRig {
	t.Helper()

	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa: %v", err)
	}
	pubJWK, err := jwk.FromRaw(rsaKey.Public())
	if err != nil {
		t.Fatalf("jwk from rsa pub: %v", err)
	}
	pubJWK.Set(jwk.KeyIDKey, testKID)
	pubJWK.Set(jwk.AlgorithmKey, jwa.RS256)
	set := jwk.NewSet()
	set.AddKey(pubJWK)

	dpopKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("ec: %v", err)
	}
	dpopJWK, err := jwk.FromRaw(dpopKey.Public())
	if err != nil {
		t.Fatalf("jwk from ec pub: %v", err)
	}
	dpopJWK.Set(jwk.AlgorithmKey, jwa.ES256)
	tp, err := dpopJWK.Thumbprint(crypto.SHA256)
	if err != nil {
		t.Fatalf("thumbprint: %v", err)
	}
	jkt := base64.RawURLEncoding.EncodeToString(tp)

	rig := &testRig{
		t:       t,
		rsaKey:  rsaKey,
		rsaJWKS: set,
		dpopKey: dpopKey,
		dpopJWK: dpopJWK,
		jktB64:  jkt,
		cache:   newMemReplayCache(),
	}
	rig.jwksServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&rig.jwksHits, 1)
		w.Header().Set("Content-Type", "application/json")
		buf, err := json.Marshal(rig.rsaJWKS)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Write(buf)
	}))
	t.Cleanup(rig.jwksServer.Close)

	rig.mw = NewMiddleware(MiddlewareConfig{
		Issuer:           testIssuer,
		ExpectedAudience: testAudience,
		JWKSEndpoint:     rig.jwksServer.URL,
		ReplayCache:      rig.cache,
		HTTPClient:       rig.jwksServer.Client(),
		Clock:            func() time.Time { return time.Unix(1_700_000_000, 0).UTC() },
	})
	return rig
}

// --- helper: build a valid JWT signed by rig.rsaKey ----------------------

type tokenOpts struct {
	iss        string
	aud        []string
	exp        time.Time
	nbf        time.Time
	iat        time.Time
	cnfJKT     string
	omitCnf    bool
	realmRoles []string
	sub        string
	kid        string
}

func (r *testRig) mintJWT(o tokenOpts) string {
	r.t.Helper()
	if o.iss == "" {
		o.iss = testIssuer
	}
	if o.aud == nil {
		o.aud = []string{testAudience}
	}
	if o.exp.IsZero() {
		o.exp = r.mw.cfg.Clock().Add(1 * time.Hour)
	}
	if o.iat.IsZero() {
		o.iat = r.mw.cfg.Clock().Add(-1 * time.Minute)
	}
	if o.cnfJKT == "" && !o.omitCnf {
		o.cnfJKT = r.jktB64
	}
	if o.sub == "" {
		o.sub = "user-1"
	}
	if o.kid == "" {
		o.kid = testKID
	}

	tok := jwt.New()
	tok.Set(jwt.IssuerKey, o.iss)
	tok.Set(jwt.AudienceKey, o.aud)
	tok.Set(jwt.SubjectKey, o.sub)
	tok.Set(jwt.ExpirationKey, o.exp)
	tok.Set(jwt.IssuedAtKey, o.iat)
	if !o.nbf.IsZero() {
		tok.Set(jwt.NotBeforeKey, o.nbf)
	}
	if !o.omitCnf {
		tok.Set("cnf", map[string]interface{}{"jkt": o.cnfJKT})
	}
	if o.realmRoles != nil {
		tok.Set("realm_access", map[string]interface{}{"roles": o.realmRoles})
	}

	hdr := jws.NewHeaders()
	hdr.Set(jws.KeyIDKey, o.kid)
	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256, r.rsaKey, jws.WithProtectedHeaders(hdr)))
	if err != nil {
		r.t.Fatalf("sign jwt: %v", err)
	}
	return string(signed)
}

// --- helper: build a DPoP proof -----------------------------------------

type dpopOpts struct {
	htm     string
	htu     string
	jti     string
	iat     int64
	jwk     jwk.Key
	alg     jwa.SignatureAlgorithm
	signKey interface{}
}

func (r *testRig) mintDPoP(o dpopOpts) string {
	r.t.Helper()
	if o.htm == "" {
		o.htm = http.MethodGet
	}
	if o.htu == "" {
		o.htu = "https://api.test/orders"
	}
	if o.jti == "" {
		o.jti = "jti-" + time.Now().Format("150405.000000000")
	}
	if o.iat == 0 {
		o.iat = r.mw.cfg.Clock().Unix()
	}
	if o.jwk == nil {
		o.jwk = r.dpopJWK
	}
	if o.alg == "" {
		o.alg = jwa.ES256
	}
	if o.signKey == nil {
		o.signKey = r.dpopKey
	}

	hdr := jws.NewHeaders()
	hdr.Set("typ", "dpop+jwt")
	hdr.Set(jws.JWKKey, o.jwk)

	payload := []byte(`{"htm":"` + o.htm + `","htu":"` + o.htu + `","iat":` + strconv.FormatInt(o.iat, 10) + `,"jti":"` + o.jti + `"}`)
	signed, err := jws.Sign(payload, jws.WithKey(o.alg, o.signKey, jws.WithProtectedHeaders(hdr)))
	if err != nil {
		r.t.Fatalf("sign dpop: %v", err)
	}
	return string(signed)
}

// --- helper: build a request with default headers -----------------------

func (r *testRig) request(method, urlStr, jwtStr, dpopStr string) *http.Request {
	r.t.Helper()
	req := httptest.NewRequest(method, urlStr, nil)
	if jwtStr != "" {
		req.Header.Set("Authorization", "Bearer "+jwtStr)
	}
	if dpopStr != "" {
		req.Header.Set("DPoP", dpopStr)
	}
	return req
}

// =========================================================================
// Tests
// =========================================================================

func TestValidateInbound_HappyPath(t *testing.T) {
	r := newRig(t)
	tok := r.mintJWT(tokenOpts{realmRoles: []string{"platform_admin"}})
	dpop := r.mintDPoP(dpopOpts{htm: "GET", htu: "https://api.test/orders"})
	req := r.request("GET", "https://api.test/orders", tok, dpop)

	claims, err := r.mw.ValidateInbound(req)
	if err != nil {
		t.Fatalf("happy path: unexpected err: %v", err)
	}
	if claims.Sub != "user-1" {
		t.Fatalf("sub: got %q want user-1", claims.Sub)
	}
	if claims.DPoPThumbprint != r.jktB64 {
		t.Fatalf("thumbprint mismatch")
	}
	if len(claims.RealmRoles) != 1 || claims.RealmRoles[0] != "platform_admin" {
		t.Fatalf("realm roles: got %v", claims.RealmRoles)
	}
}

func TestValidateInbound_ErrorPaths(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(rig *testRig) *http.Request
		wantErr error
	}{
		{
			name: "no_authorization_header",
			mutate: func(rig *testRig) *http.Request {
				dpop := rig.mintDPoP(dpopOpts{})
				return rig.request("GET", "https://api.test/orders", "", dpop)
			},
			wantErr: ErrInvalidToken,
		},
		{
			name: "non_bearer_scheme",
			mutate: func(rig *testRig) *http.Request {
				req := rig.request("GET", "https://api.test/orders", "", rig.mintDPoP(dpopOpts{}))
				req.Header.Set("Authorization", "Basic abc")
				return req
			},
			wantErr: ErrInvalidToken,
		},
		{
			name: "garbage_jwt",
			mutate: func(rig *testRig) *http.Request {
				return rig.request("GET", "https://api.test/orders", "garbage", rig.mintDPoP(dpopOpts{}))
			},
			wantErr: ErrInvalidToken,
		},
		{
			name: "wrong_issuer",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{iss: "https://imposter/realms/x"})
				return rig.request("GET", "https://api.test/orders", tok, rig.mintDPoP(dpopOpts{}))
			},
			wantErr: ErrInvalidToken,
		},
		{
			name: "wrong_audience",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{aud: []string{"https://other.test"}})
				return rig.request("GET", "https://api.test/orders", tok, rig.mintDPoP(dpopOpts{}))
			},
			wantErr: ErrAudienceMismatch,
		},
		{
			name: "expired",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{exp: rig.mw.cfg.Clock().Add(-1 * time.Hour)})
				return rig.request("GET", "https://api.test/orders", tok, rig.mintDPoP(dpopOpts{}))
			},
			wantErr: ErrTokenExpired,
		},
		{
			name: "iat_in_future_beyond_skew",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{iat: rig.mw.cfg.Clock().Add(5 * time.Minute)})
				return rig.request("GET", "https://api.test/orders", tok, rig.mintDPoP(dpopOpts{}))
			},
			wantErr: ErrInvalidToken,
		},
		{
			name: "missing_dpop",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{})
				return rig.request("GET", "https://api.test/orders", tok, "")
			},
			wantErr: ErrDPoPMissing,
		},
		{
			name: "dpop_garbage",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{})
				return rig.request("GET", "https://api.test/orders", tok, "not-a-dpop")
			},
			wantErr: ErrDPoPMismatch,
		},
		{
			name: "dpop_htm_mismatch",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{})
				dpop := rig.mintDPoP(dpopOpts{htm: "POST"})
				return rig.request("GET", "https://api.test/orders", tok, dpop)
			},
			wantErr: ErrDPoPMismatch,
		},
		{
			name: "dpop_htu_mismatch",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{})
				dpop := rig.mintDPoP(dpopOpts{htu: "https://api.test/other"})
				return rig.request("GET", "https://api.test/orders", tok, dpop)
			},
			wantErr: ErrDPoPMismatch,
		},
		{
			name: "dpop_iat_too_old",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{})
				dpop := rig.mintDPoP(dpopOpts{iat: rig.mw.cfg.Clock().Unix() - 3600})
				return rig.request("GET", "https://api.test/orders", tok, dpop)
			},
			wantErr: ErrDPoPMismatch,
		},
		{
			name: "dpop_jkt_does_not_match_cnf",
			mutate: func(rig *testRig) *http.Request {
				// JWT carries a totally different cnf.jkt than the DPoP key's
				// real thumbprint.
				tok := rig.mintJWT(tokenOpts{cnfJKT: "ZZZdifferent_thumbprintZZZ"})
				dpop := rig.mintDPoP(dpopOpts{})
				return rig.request("GET", "https://api.test/orders", tok, dpop)
			},
			wantErr: ErrDPoPMismatch,
		},
		{
			name: "missing_cnf_claim",
			mutate: func(rig *testRig) *http.Request {
				tok := rig.mintJWT(tokenOpts{omitCnf: true})
				dpop := rig.mintDPoP(dpopOpts{})
				return rig.request("GET", "https://api.test/orders", tok, dpop)
			},
			wantErr: ErrDPoPMismatch,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rig := newRig(t)
			req := tc.mutate(rig)
			_, err := rig.mw.ValidateInbound(req)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("got %v, want %v", err, tc.wantErr)
			}
		})
	}
}

func TestValidateInbound_DPoPReplay(t *testing.T) {
	r := newRig(t)
	tok := r.mintJWT(tokenOpts{})
	dpop := r.mintDPoP(dpopOpts{jti: "replay-once"})
	first := r.request("GET", "https://api.test/orders", tok, dpop)
	second := r.request("GET", "https://api.test/orders", tok, dpop)

	if _, err := r.mw.ValidateInbound(first); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if _, err := r.mw.ValidateInbound(second); !errors.Is(err, ErrDPoPMismatch) {
		t.Fatalf("replay should fail with DPoP mismatch, got %v", err)
	}
}

func TestValidateInbound_JWKSCacheMissRefreshes(t *testing.T) {
	r := newRig(t)
	// Force a kid the JWKS doesn't have, then add it after one call.
	bogusKid := "rotated-kid"
	tok := r.mintJWT(tokenOpts{kid: bogusKid})
	dpop := r.mintDPoP(dpopOpts{})

	// First call: kid unknown to current cache; refresh fetches the same
	// (still-doesn't-have-it) JWKS, so this fails — but we should observe
	// 2 hits to the JWKS endpoint (initial + refresh-on-miss).
	atomic.StoreInt64(&r.jwksHits, 0)
	req := r.request("GET", "https://api.test/orders", tok, dpop)
	if _, err := r.mw.ValidateInbound(req); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("expected ErrInvalidToken, got %v", err)
	}
	if got := atomic.LoadInt64(&r.jwksHits); got != 2 {
		t.Fatalf("expected exactly 2 JWKS fetches (initial + refresh), got %d", got)
	}

	// Now add the new kid to the JWKS and retry — the second call hits the
	// cache (still warm post-refresh) and observes the new kid is still
	// missing; force a third fetch by waiting for cache TTL would be slow,
	// so we use a fresh Middleware to confirm the happy path with the
	// rotated kid.
	pubJWK, _ := jwk.FromRaw(r.rsaKey.Public())
	pubJWK.Set(jwk.KeyIDKey, bogusKid)
	pubJWK.Set(jwk.AlgorithmKey, jwa.RS256)
	r.rsaJWKS.AddKey(pubJWK)

	r2 := newMiddlewareWithRig(r)
	if _, err := r2.ValidateInbound(req); err != nil {
		t.Fatalf("rotated kid: %v", err)
	}
}

func newMiddlewareWithRig(r *testRig) *Middleware {
	return NewMiddleware(MiddlewareConfig{
		Issuer:           testIssuer,
		ExpectedAudience: testAudience,
		JWKSEndpoint:     r.jwksServer.URL,
		ReplayCache:      newMemReplayCache(),
		HTTPClient:       r.jwksServer.Client(),
		Clock:            r.mw.cfg.Clock,
	})
}

func TestCanonicalHTU(t *testing.T) {
	cases := []struct {
		name   string
		method string
		url    string
		host   string
		fwdP   string
		fwdH   string
		tls    bool
		want   string
	}{
		{
			name: "x_forwarded_present",
			url:  "/api/orders",
			host: "internal-svc:8080",
			fwdP: "https",
			fwdH: "app.secforge.local",
			want: "https://app.secforge.local/api/orders",
		},
		{
			name: "no_forwarded_https",
			url:  "/api/orders",
			host: "api.test:443",
			tls:  true,
			want: "https://api.test/api/orders",
		},
		{
			name: "no_forwarded_http",
			url:  "/api/orders",
			host: "api.test:80",
			tls:  false,
			want: "http://api.test/api/orders",
		},
		{
			name: "non_default_port_kept",
			url:  "/api/orders",
			host: "api.test:8443",
			tls:  true,
			want: "https://api.test:8443/api/orders",
		},
		{
			name: "uppercase_host_lowered",
			url:  "/api/orders",
			host: "API.TEST",
			tls:  true,
			want: "https://api.test/api/orders",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "https://placeholder"+tc.url, nil)
			req.Host = tc.host
			if tc.fwdP != "" {
				req.Header.Set("X-Forwarded-Proto", tc.fwdP)
			}
			if tc.fwdH != "" {
				req.Header.Set("X-Forwarded-Host", tc.fwdH)
			}
			if !tc.tls {
				req.TLS = nil
			}
			got := canonicalHTU(req)
			if got != tc.want {
				t.Errorf("canonicalHTU=%q want=%q", got, tc.want)
			}
		})
	}
}

func TestErrorToHTTP(t *testing.T) {
	cases := []struct {
		err    error
		status int
		short  string
	}{
		{ErrInvalidToken, http.StatusUnauthorized, "invalid_token"},
		{ErrTokenExpired, http.StatusUnauthorized, "token_expired"},
		{ErrAudienceMismatch, http.StatusUnauthorized, "audience_mismatch"},
		{ErrDPoPMissing, http.StatusUnauthorized, "dpop_missing"},
		{ErrDPoPMismatch, http.StatusUnauthorized, "dpop_mismatch"},
		{ErrAudienceNotConfigured, http.StatusInternalServerError, "audience_not_configured"},
		{ErrAudienceUnavailable, http.StatusUnauthorized, "audience_unavailable"},
		{ErrKeycloakUnreachable, http.StatusBadGateway, "keycloak_unreachable"},
	}
	for _, tc := range cases {
		t.Run(tc.short, func(t *testing.T) {
			s, sh := errorToHTTP(tc.err)
			if s != tc.status || sh != tc.short {
				t.Fatalf("got (%d,%s) want (%d,%s)", s, sh, tc.status, tc.short)
			}
		})
	}
}

func TestWrap_DeniedRequest(t *testing.T) {
	r := newRig(t)
	h := r.mw.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Fatalf("inner handler should not run on denial")
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r.request("GET", "https://api.test/orders", "", ""))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d want 401", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "invalid_token") {
		t.Fatalf("body %q missing invalid_token", rec.Body.String())
	}
}

func TestWrap_AllowedRequest(t *testing.T) {
	r := newRig(t)
	tok := r.mintJWT(tokenOpts{})
	dpop := r.mintDPoP(dpopOpts{})
	innerCalled := false
	h := r.mw.Wrap(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		innerCalled = true
		c := ClaimsFromContext(req.Context())
		if c == nil || c.Sub != "user-1" {
			t.Fatalf("claims not in context: %+v", c)
		}
		w.WriteHeader(http.StatusOK)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r.request("GET", "https://api.test/orders", tok, dpop))
	if !innerCalled {
		t.Fatalf("inner handler not called")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
}
