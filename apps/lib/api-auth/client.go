package apiauth

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

// randomID returns a 128-bit random identifier base64url-encoded — used
// for `jti` in DPoP proofs and `client_assertion` JWS. Avoids adding
// google/uuid as a dependency for this single use.
func randomID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// sessionKeyCtx is the typed context key under which callers attach the
// user's session-store key (the value that SessionStore.GetSession indexes
// on). The BFF sets this from the inbound session cookie before calling
// MintTokenForAudience.
type sessionKeyCtx struct{}

// ContextWithSessionKey attaches the SessionStore lookup key to ctx.
func ContextWithSessionKey(ctx context.Context, key string) context.Context {
	return context.WithValue(ctx, sessionKeyCtx{}, key)
}

// SessionKeyFromContext returns the value attached by ContextWithSessionKey,
// or "" if none.
func SessionKeyFromContext(ctx context.Context) string {
	v, _ := ctx.Value(sessionKeyCtx{}).(string)
	return v
}

// Client mints downstream-API-scoped, DPoP-bound access tokens from a user
// session via Keycloak refresh with expanded scope (audience-at-login per
// ADR-0012/0014). It never calls RFC 8693 token-exchange.
type Client struct {
	cfg ClientConfig
}

// NewClient returns a Client. The constructor performs no I/O.
func NewClient(cfg ClientConfig) *Client {
	return &Client{cfg: cfg}
}

// MintTokenForAudience returns an access token whose `aud` claim contains
// aud and whose `cnf.jkt` is bound to ClientConfig.DPoPKey's thumbprint.
//
// Per ADR-0014:
//
//   - aud must be in ClientConfig.AudienceList (Q2 static config). If not,
//     returns ErrAudienceNotConfigured immediately without ever contacting
//     Keycloak.
//   - If the cached SessionTokens already cover aud and have ≥30s of life
//     left, the cached AccessToken is returned without contacting Keycloak.
//   - Otherwise, a refresh-with-expanded-scope request is sent to
//     ClientConfig.TokenEndpoint. Outcomes:
//     200 OK → cache + return new token (Q3 outcome (a))
//     4xx invalid_scope/invalid_grant/etc. → ErrAudienceUnavailable
//     (Q3 outcome (b)); BFF translates to 401 + clear-session
//     5xx / transport error → ErrKeycloakUnreachable
//
// MUST NOT panic on any input. The DPoP proof for the upstream call is
// the caller's responsibility — this function only obtains the access
// token; the caller mints a fresh DPoP proof scoped to the upstream URL
// when forwarding.
func (c *Client) MintTokenForAudience(ctx context.Context, aud string) (string, error) {
	// Step 1 — AudienceList short-circuit (Q2: static config wins).
	if !contains(c.cfg.AudienceList, aud) {
		return "", ErrAudienceNotConfigured
	}

	sessKey := SessionKeyFromContext(ctx)
	if sessKey == "" {
		return "", fmt.Errorf("%w: no session key in context", ErrInvalidToken)
	}

	// Step 2 — Cache hit?
	tokens, err := c.cfg.SessionStore.GetSession(ctx, sessKey)
	if err != nil {
		return "", ErrKeycloakUnreachable
	}
	if tokens == nil {
		// No session — caller's job to (re)login.
		return "", ErrAudienceUnavailable
	}
	now := c.now()
	if contains(tokens.Audiences, aud) && tokens.ExpiresAt.After(now.Add(30*time.Second)) {
		return tokens.AccessToken, nil
	}

	// Step 3 — refresh with expanded scope.
	if tokens.RefreshToken == "" {
		return "", ErrAudienceUnavailable
	}
	newTokens, err := c.refreshWithExpandedScope(ctx, tokens, aud)
	if err != nil {
		return "", err
	}

	// Defense in depth: the new access token's aud must include the
	// requested audience (Keycloak should already enforce, but assert).
	parsedNew, perr := jwt.ParseInsecure([]byte(newTokens.AccessToken))
	if perr != nil {
		return "", ErrAudienceUnavailable
	}
	if !audContains(parsedNew.Audience(), aud) {
		return "", ErrAudienceUnavailable
	}

	// Step 4 — persist.
	if err := c.cfg.SessionStore.PutSession(ctx, sessKey, newTokens); err != nil {
		// Persistence failure is not a hard error for the current request;
		// the caller still got a usable access token. Surface as audit at
		// the call site rather than an error here.
		_ = err
	}
	return newTokens.AccessToken, nil
}

// refreshWithExpandedScope POSTs to TokenEndpoint with grant_type=refresh_token
// + private_key_jwt + scope expanded to include aud. Returns the parsed
// SessionTokens on success or a typed error on Keycloak-side rejection or
// transport failure.
func (c *Client) refreshWithExpandedScope(ctx context.Context, prev *SessionTokens, aud string) (*SessionTokens, error) {
	clientAssertion, err := c.makeClientAssertion()
	if err != nil {
		return nil, ErrInvalidToken
	}
	dpopProof, err := c.makeDPoPProof(http.MethodPost, c.cfg.TokenEndpoint)
	if err != nil {
		return nil, ErrInvalidToken
	}

	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", prev.RefreshToken)
	form.Set("client_id", c.cfg.ClientID)
	form.Set("client_assertion", clientAssertion)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("scope", expandScope(prev.Audiences, aud))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, ErrKeycloakUnreachable
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("DPoP", dpopProof)

	httpClient := c.cfg.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, ErrKeycloakUnreachable
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 500 {
		return nil, ErrKeycloakUnreachable
	}
	if resp.StatusCode >= 400 {
		// Keycloak returns JSON {error: invalid_scope|invalid_grant|...}.
		// All 4xx outcomes funnel into ErrAudienceUnavailable per ADR-0014.
		return nil, ErrAudienceUnavailable
	}

	var tokRes struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tokRes); err != nil {
		return nil, ErrAudienceUnavailable
	}
	if tokRes.AccessToken == "" {
		return nil, ErrAudienceUnavailable
	}

	parsed, err := jwt.ParseInsecure([]byte(tokRes.AccessToken))
	if err != nil {
		return nil, ErrAudienceUnavailable
	}
	return &SessionTokens{
		AccessToken:  tokRes.AccessToken,
		RefreshToken: tokRes.RefreshToken,
		ExpiresAt:    c.now().Add(time.Duration(tokRes.ExpiresIn) * time.Second),
		Audiences:    parsed.Audience(),
	}, nil
}

// makeClientAssertion returns a private_key_jwt JWS signed by
// ClientConfig.ClientAssertionPEM, suitable for the `client_assertion` form
// parameter. RFC 7523 § 2.2.
func (c *Client) makeClientAssertion() (string, error) {
	rsaKey, err := parseRSAPrivateKey(c.cfg.ClientAssertionPEM)
	if err != nil {
		return "", err
	}
	now := c.now()
	tok := jwt.New()
	tok.Set(jwt.IssuerKey, c.cfg.ClientID)
	tok.Set(jwt.SubjectKey, c.cfg.ClientID)
	tok.Set(jwt.AudienceKey, c.cfg.TokenEndpoint)
	tok.Set(jwt.IssuedAtKey, now)
	tok.Set(jwt.ExpirationKey, now.Add(60*time.Second))
	tok.Set(jwt.JwtIDKey, randomID())

	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256, rsaKey))
	if err != nil {
		return "", err
	}
	return string(signed), nil
}

// makeDPoPProof returns a DPoP JWS for the given (htm, htu), signed by
// ClientConfig.DPoPKey, with a fresh jti and current iat. The embedded
// jwk lets the verifier (Keycloak / upstream) check the signature
// without prior key registration.
func (c *Client) makeDPoPProof(htm, htu string) (string, error) {
	pubJWK, err := jwk.PublicKeyOf(c.cfg.DPoPKey)
	if err != nil {
		return "", err
	}
	pubJWK.Set(jwk.AlgorithmKey, jwa.ES256)

	hdr := jws.NewHeaders()
	hdr.Set("typ", "dpop+jwt")
	hdr.Set(jws.JWKKey, pubJWK)

	now := c.now()
	payload, _ := json.Marshal(struct {
		HTM string `json:"htm"`
		HTU string `json:"htu"`
		IAT int64  `json:"iat"`
		JTI string `json:"jti"`
	}{HTM: htm, HTU: htu, IAT: now.Unix(), JTI: randomID()})

	signed, err := jws.Sign(payload, jws.WithKey(jwa.ES256, c.cfg.DPoPKey, jws.WithProtectedHeaders(hdr)))
	if err != nil {
		return "", err
	}
	return string(signed), nil
}

// DPoPKeyThumbprint returns the SHA-256 thumbprint (RFC 7638) of the
// configured DPoP key, base64url-encoded. This is the same value that
// Keycloak stamps into `cnf.jkt` on tokens minted via this Client. The BFF
// uses it for diagnostic logging and as a sanity check against the access
// token's cnf claim.
func (c *Client) DPoPKeyThumbprint() (string, error) {
	pubJWK, err := jwk.PublicKeyOf(c.cfg.DPoPKey)
	if err != nil {
		return "", err
	}
	tp, err := pubJWK.Thumbprint(crypto.SHA256)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(tp), nil
}

func (c *Client) now() time.Time {
	if c.cfg.Clock != nil {
		return c.cfg.Clock()
	}
	return time.Now()
}

// parseRSAPrivateKey accepts either PKCS#1 or PKCS#8 PEM-encoded RSA keys.
func parseRSAPrivateKey(pemBytes []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apiauth: client assertion PEM has no PEM block")
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	rsaKey, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("apiauth: client assertion key is not RSA")
	}
	return rsaKey, nil
}

// expandScope adds the audience as a scope value if not already present.
// Keycloak's audience-mapper-on-client-scope convention treats the audience
// name as a scope; including it on refresh causes the AS to add it to the
// resulting token's aud claim.
func expandScope(existing []string, aud string) string {
	parts := []string{"openid", "profile", "email"}
	seen := map[string]bool{"openid": true, "profile": true, "email": true}
	for _, e := range existing {
		if !seen[e] {
			parts = append(parts, e)
			seen[e] = true
		}
	}
	if !seen[aud] {
		parts = append(parts, aud)
	}
	return strings.Join(parts, " ")
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
