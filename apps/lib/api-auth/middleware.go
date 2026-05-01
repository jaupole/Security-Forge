package apiauth

import (
	"context"
	"crypto"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

const (
	dpopAcceptWindow = 60 * time.Second
	clockSkew        = 30 * time.Second
	replayCacheTTL   = 90 * time.Second
	jwksCacheTTL     = 1 * time.Hour
)

// claimsCtxKey is the typed context key under which Wrap attaches *Claims.
type claimsCtxKey struct{}

// ClaimsFromContext returns the *Claims attached by Wrap, or nil if absent.
func ClaimsFromContext(ctx context.Context) *Claims {
	v, _ := ctx.Value(claimsCtxKey{}).(*Claims)
	return v
}

// Middleware validates inbound user-tier JWT+DPoP requests against
// Keycloak's JWKS and the configured audience. See ADR-0014 § Library API
// surface. Construct via NewMiddleware; one Middleware instance accepts a
// single audience.
type Middleware struct {
	cfg MiddlewareConfig

	jwksMu      sync.Mutex
	jwksCache   jwk.Set
	jwksExpires time.Time
}

// NewMiddleware returns a Middleware ready to validate inbound requests.
// The constructor performs no I/O; JWKS fetches happen lazily on the first
// ValidateInbound call.
func NewMiddleware(cfg MiddlewareConfig) *Middleware {
	return &Middleware{cfg: cfg}
}

// ValidateInbound performs the 17-step JWT+DPoP validation chain documented
// in ADR-0014 and phase-06b-api-pattern.md § Section 3. Returns *Claims on
// success; on failure returns one of the typed errors in errors.go (caller
// translates to HTTP per the mapping table there).
//
// MUST NOT panic on any input; all paths return a typed error.
func (m *Middleware) ValidateInbound(req *http.Request) (*Claims, error) {
	now := m.now()

	// Step 1: Authorization header present + Bearer prefix.
	auth := req.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, ErrInvalidToken
	}
	rawJWT := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	if rawJWT == "" {
		return nil, ErrInvalidToken
	}

	// Step 2: parse the JWS structure (defer signature verify to step 3).
	jwsMsg, err := jws.Parse([]byte(rawJWT))
	if err != nil || len(jwsMsg.Signatures()) == 0 {
		return nil, ErrInvalidToken
	}
	kid := jwsMsg.Signatures()[0].ProtectedHeaders().KeyID()

	// Step 3: verify signature against the JWKS (with refresh on kid miss).
	key, err := m.lookupKey(req.Context(), kid)
	if err != nil {
		return nil, err
	}
	parsed, err := jwt.Parse([]byte(rawJWT), jwt.WithKey(jwsMsg.Signatures()[0].ProtectedHeaders().Algorithm(), key), jwt.WithVerify(true), jwt.WithValidate(false))
	if err != nil {
		return nil, ErrInvalidToken
	}

	// Step 4: iss exact match.
	if parsed.Issuer() != m.cfg.Issuer {
		return nil, ErrInvalidToken
	}

	// Step 5: aud contains ExpectedAudience.
	if !audContains(parsed.Audience(), m.cfg.ExpectedAudience) {
		return nil, ErrAudienceMismatch
	}

	// Step 6: exp > now.
	exp := parsed.Expiration()
	if exp.IsZero() || !exp.After(now) {
		return nil, ErrTokenExpired
	}

	// Step 7: nbf <= now (skew tolerated).
	if nbf := parsed.NotBefore(); !nbf.IsZero() && nbf.After(now.Add(clockSkew)) {
		return nil, ErrInvalidToken
	}

	// Step 8: iat <= now (skew tolerated).
	if iat := parsed.IssuedAt(); !iat.IsZero() && iat.After(now.Add(clockSkew)) {
		return nil, ErrInvalidToken
	}

	// Step 9: DPoP header present.
	dpopRaw := req.Header.Get("DPoP")
	if dpopRaw == "" {
		return nil, ErrDPoPMissing
	}

	// Step 10: DPoP parses as JWS with embedded jwk.
	dpopMsg, err := jws.Parse([]byte(dpopRaw))
	if err != nil || len(dpopMsg.Signatures()) == 0 {
		return nil, ErrDPoPMismatch
	}
	dpopProtected := dpopMsg.Signatures()[0].ProtectedHeaders()
	embeddedJWK := dpopProtected.JWK()
	if embeddedJWK == nil {
		return nil, ErrDPoPMismatch
	}

	// Step 11: DPoP signature verifies with embedded jwk.
	var dpopPayload []byte
	if dpopPayload, err = jws.Verify([]byte(dpopRaw), jws.WithKey(dpopProtected.Algorithm(), embeddedJWK)); err != nil {
		return nil, ErrDPoPMismatch
	}
	var dpopClaims struct {
		HTM string `json:"htm"`
		HTU string `json:"htu"`
		IAT int64  `json:"iat"`
		JTI string `json:"jti"`
	}
	if err := json.Unmarshal(dpopPayload, &dpopClaims); err != nil {
		return nil, ErrDPoPMismatch
	}

	// Step 12: htm matches request method.
	if !strings.EqualFold(dpopClaims.HTM, req.Method) {
		return nil, ErrDPoPMismatch
	}

	// Step 13: htu matches canonicalized request URL.
	if dpopClaims.HTU != canonicalHTU(req) {
		return nil, ErrDPoPMismatch
	}

	// Step 14: DPoP iat within ±60 s of now.
	dpopIAT := time.Unix(dpopClaims.IAT, 0)
	delta := now.Sub(dpopIAT)
	if delta < -dpopAcceptWindow || delta > dpopAcceptWindow {
		return nil, ErrDPoPMismatch
	}

	// Step 15: jti not in replay cache (atomic insert; concurrent caller
	// observes true).
	if dpopClaims.JTI == "" {
		return nil, ErrDPoPMismatch
	}
	seen, cacheErr := m.cfg.ReplayCache.SeenWithin(req.Context(), dpopClaims.JTI, replayCacheTTL)
	if cacheErr != nil {
		return nil, ErrDPoPMismatch
	}
	if seen {
		return nil, ErrDPoPMismatch
	}

	// Step 16: SHA-256 thumbprint of embedded jwk == access token's cnf.jkt
	// (RFC 7638 thumbprint, per RFC 9449).
	tp, err := embeddedJWK.Thumbprint(crypto.SHA256)
	if err != nil {
		return nil, ErrDPoPMismatch
	}
	dpopThumbprint := base64.RawURLEncoding.EncodeToString(tp)
	cnfJKT, ok := readCnfJKT(parsed)
	if !ok || cnfJKT != dpopThumbprint {
		return nil, ErrDPoPMismatch
	}

	// Step 17: insertion already happened atomically in step 15 (the
	// SeenWithin contract is "atomic insert if absent"); nothing more to do.

	// Build *Claims for the caller.
	claims := &Claims{
		Sub:            parsed.Subject(),
		Aud:            parsed.Audience(),
		DPoPThumbprint: dpopThumbprint,
	}
	if roles, ok := readRealmRoles(parsed); ok {
		claims.RealmRoles = roles
	}
	if spiffeID := readSPIFFEFromTLS(req); spiffeID != "" {
		claims.SPIFFEID = &spiffeID
	}
	return claims, nil
}

// Wrap returns an http.Handler that runs ValidateInbound on every request.
// On success, attaches *Claims to the request context and forwards to next.
// On failure, writes the ADR-0014-mapped HTTP status and a JSON error body
// and emits one audit-log line if MiddlewareConfig.Audit is non-nil.
//
// The audit-log line is emitted on success too — every protected request
// produces an audit entry per ADR-0014 § Library API surface.
func (m *Middleware) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, err := m.ValidateInbound(r)
		if err != nil {
			status, short := errorToHTTP(err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			io.WriteString(w, `{"error":"`+short+`"}`)
			if m.cfg.Audit != nil {
				_ = m.cfg.Audit.LogHop(r, 0, m.cfg.WorkloadID, "", m.cfg.ExpectedAudience, status)
			}
			return
		}
		ctx := context.WithValue(r.Context(), claimsCtxKey{}, claims)
		if m.cfg.Audit != nil {
			_ = m.cfg.Audit.LogHop(r, 0, m.cfg.WorkloadID, claims.Sub, m.cfg.ExpectedAudience, http.StatusOK)
		}
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// errorToHTTP maps a sentinel error to the canonical (status, short-string)
// pair from ADR-0014 § Error-handling contract.
func errorToHTTP(err error) (int, string) {
	switch {
	case errors.Is(err, ErrInvalidToken):
		return http.StatusUnauthorized, "invalid_token"
	case errors.Is(err, ErrTokenExpired):
		return http.StatusUnauthorized, "token_expired"
	case errors.Is(err, ErrAudienceMismatch):
		return http.StatusUnauthorized, "audience_mismatch"
	case errors.Is(err, ErrDPoPMissing):
		return http.StatusUnauthorized, "dpop_missing"
	case errors.Is(err, ErrDPoPMismatch):
		return http.StatusUnauthorized, "dpop_mismatch"
	case errors.Is(err, ErrAudienceNotConfigured):
		return http.StatusInternalServerError, "audience_not_configured"
	case errors.Is(err, ErrAudienceUnavailable):
		return http.StatusUnauthorized, "audience_unavailable"
	case errors.Is(err, ErrKeycloakUnreachable):
		return http.StatusBadGateway, "keycloak_unreachable"
	default:
		return http.StatusInternalServerError, "internal_error"
	}
}

// lookupKey returns the JWKS entry for kid, refreshing the cache once on
// miss before returning ErrInvalidToken.
func (m *Middleware) lookupKey(ctx context.Context, kid string) (jwk.Key, error) {
	keys, err := m.getJWKS(ctx, false)
	if err != nil {
		return nil, ErrInvalidToken
	}
	if k, ok := keys.LookupKeyID(kid); ok {
		return k, nil
	}
	keys, err = m.getJWKS(ctx, true)
	if err != nil {
		return nil, ErrInvalidToken
	}
	if k, ok := keys.LookupKeyID(kid); ok {
		return k, nil
	}
	return nil, ErrInvalidToken
}

// getJWKS returns the cached set, fetching/refreshing if absent, expired,
// or forced (kid-miss path).
func (m *Middleware) getJWKS(ctx context.Context, force bool) (jwk.Set, error) {
	m.jwksMu.Lock()
	defer m.jwksMu.Unlock()
	if !force && m.jwksCache != nil && time.Now().Before(m.jwksExpires) {
		return m.jwksCache, nil
	}
	httpClient := m.cfg.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.cfg.JWKSEndpoint, nil)
	if err != nil {
		return nil, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks endpoint returned %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	set, err := jwk.Parse(body)
	if err != nil {
		return nil, err
	}
	m.jwksCache = set
	m.jwksExpires = time.Now().Add(jwksCacheTTL)
	return set, nil
}

func (m *Middleware) now() time.Time {
	if m.cfg.Clock != nil {
		return m.cfg.Clock()
	}
	return time.Now()
}

// canonicalHTU computes the DPoP `htu` per RFC 9449 §4.3 and the platform's
// docs/06-reference/dpop-htu-canonicalization.md. Prefers X-Forwarded-Proto
// + X-Forwarded-Host when both are present (proxy-in-path case); otherwise
// derives scheme from req.TLS and host from req.Host. Path is taken
// verbatim — no normalization. Query string and fragment are stripped.
func canonicalHTU(req *http.Request) string {
	var scheme, host string
	fwdProto := req.Header.Get("X-Forwarded-Proto")
	fwdHost := req.Header.Get("X-Forwarded-Host")
	if fwdProto != "" && fwdHost != "" {
		scheme = strings.ToLower(strings.TrimSpace(fwdProto))
		host = strings.ToLower(strings.TrimSpace(fwdHost))
	} else {
		if req.TLS != nil {
			scheme = "https"
		} else {
			scheme = "http"
		}
		host = strings.ToLower(req.Host)
	}
	host = stripDefaultPort(host, scheme)
	return scheme + "://" + host + req.URL.Path
}

// stripDefaultPort drops :443 from https hosts and :80 from http hosts.
// IPv6 literals stay intact (the bracket form keeps :port unambiguous).
func stripDefaultPort(host, scheme string) string {
	switch scheme {
	case "https":
		host = strings.TrimSuffix(host, ":443")
	case "http":
		host = strings.TrimSuffix(host, ":80")
	}
	return host
}

// readCnfJKT extracts the cnf.jkt thumbprint from the JWT. Returns
// (jkt, true) if present and well-typed, ("", false) otherwise.
func readCnfJKT(t jwt.Token) (string, bool) {
	cnf, ok := t.Get("cnf")
	if !ok {
		return "", false
	}
	cnfMap, ok := cnf.(map[string]interface{})
	if !ok {
		return "", false
	}
	jkt, ok := cnfMap["jkt"].(string)
	if !ok || jkt == "" {
		return "", false
	}
	return jkt, true
}

// readRealmRoles extracts realm_access.roles from the JWT, if present.
func readRealmRoles(t jwt.Token) ([]string, bool) {
	ra, ok := t.Get("realm_access")
	if !ok {
		return nil, false
	}
	raMap, ok := ra.(map[string]interface{})
	if !ok {
		return nil, false
	}
	rolesRaw, ok := raMap["roles"].([]interface{})
	if !ok {
		return nil, false
	}
	roles := make([]string, 0, len(rolesRaw))
	for _, r := range rolesRaw {
		if s, ok := r.(string); ok {
			roles = append(roles, s)
		}
	}
	return roles, true
}

// readSPIFFEFromTLS pulls the first SPIFFE-SVID URI from the TLS peer cert
// chain. Returns "" if no mTLS or no SPIFFE URI present.
func readSPIFFEFromTLS(req *http.Request) string {
	if req.TLS == nil {
		return ""
	}
	for _, cert := range req.TLS.PeerCertificates {
		for _, u := range cert.URIs {
			if u.Scheme == "spiffe" {
				return u.String()
			}
		}
	}
	return ""
}

// audContains reports whether want appears in aud.
func audContains(aud []string, want string) bool {
	for _, a := range aud {
		if a == want {
			return true
		}
	}
	return false
}
