package main

// OIDC client wiring: Keycloak discovery, PAR + DPoP + PKCE auth-code,
// token refresh, end-session URL, RFC 7009 revocation. The BFF
// authenticates to Keycloak with private_key_jwt (client_assertion).

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/google/uuid"
	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

type oidcClient struct {
	cfg            cfg
	issuer         string
	clientPriv     *rsa.PrivateKey
	clientKid      string // RFC 7638 thumbprint of the public key — must match Keycloak's registered kid
	provider       *oidc.Provider
	verifier       *oidc.IDTokenVerifier
	endpoints      oidcEndpoints
	hc             *http.Client
}

type oidcEndpoints struct {
	Issuer                string `json:"issuer"`
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	PAREndpoint           string `json:"pushed_authorization_request_endpoint"`
	RevocationEndpoint    string `json:"revocation_endpoint"`
	EndSessionEndpoint    string `json:"end_session_endpoint"`
}

func newOIDC(ctx context.Context, c cfg, clientPrivPEM []byte) (*oidcClient, error) {
	priv, err := parseRSAPriv(clientPrivPEM)
	if err != nil {
		return nil, fmt.Errorf("parse client private key: %w", err)
	}
	// Keycloak's kid for jwt.credential.public.key clients is
	// base64url(SHA-256(DER-PKIX-encoded public key)). NOT RFC 7638
	// thumbprint — empirically verified against Keycloak 26.x. If we
	// signed the assertion with an RFC 7638 kid (over JWK canonical
	// JSON), Keycloak rejects with "PublicKey wasn't found in the
	// storage. Available kids: [<DER-SHA256-kid>]".
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("marshal pubkey DER: %w", err)
	}
	pubSum := sha256.Sum256(pubDER)
	kid := base64.RawURLEncoding.EncodeToString(pubSum[:])
	prov, err := oidc.NewProvider(ctx, c.KCIssuer)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery: %w", err)
	}
	var ep oidcEndpoints
	if err := prov.Claims(&ep); err != nil {
		return nil, fmt.Errorf("decode discovery: %w", err)
	}
	if ep.PAREndpoint == "" || ep.EndSessionEndpoint == "" {
		return nil, errors.New("issuer missing PAR or end_session endpoint")
	}
	v := prov.Verifier(&oidc.Config{ClientID: c.KCClientID})
	slog.Info("oidc client ready", "client_id", c.KCClientID, "kid", kid)
	return &oidcClient{
		cfg:        c,
		issuer:     c.KCIssuer,
		clientPriv: priv,
		clientKid:  kid,
		provider:   prov,
		verifier:   v,
		endpoints:  ep,
		hc:         &http.Client{Timeout: 15 * time.Second},
	}, nil
}

func (o *oidcClient) ping(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", o.issuer+"/.well-known/openid-configuration", nil)
	resp, err := o.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("issuer probe %d", resp.StatusCode)
	}
	return nil
}

// clientAssertion mints a private_key_jwt for the BFF's Keycloak client.
// The `kid` header MUST match Keycloak's stored client public-key kid;
// otherwise the assertion is rejected with `Authentication failed.`
func (o *oidcClient) clientAssertion(audience string) (string, error) {
	t := jwt.New()
	now := time.Now()
	_ = t.Set(jwt.IssuerKey, o.cfg.KCClientID)
	_ = t.Set(jwt.SubjectKey, o.cfg.KCClientID)
	_ = t.Set(jwt.AudienceKey, audience)
	_ = t.Set(jwt.JwtIDKey, uuid.NewString())
	_ = t.Set(jwt.IssuedAtKey, now)
	_ = t.Set(jwt.ExpirationKey, now.Add(60*time.Second))
	hdrs := jws.NewHeaders()
	_ = hdrs.Set(jws.KeyIDKey, o.clientKid)
	signed, err := jwt.Sign(t, jwt.WithKey(jwa.PS256, o.clientPriv, jws.WithProtectedHeaders(hdrs)))
	if err != nil {
		return "", err
	}
	return string(signed), nil
}

// par pushes the authorization request and returns the request_uri.
func (o *oidcClient) par(ctx context.Context, dpop *dpopSigner, redirectURI, state, nonce, codeChallenge string) (string, error) {
	assertion, err := o.clientAssertion(o.endpoints.TokenEndpoint)
	if err != nil {
		return "", err
	}
	form := url.Values{}
	form.Set("response_type", "code")
	form.Set("client_id", o.cfg.KCClientID)
	form.Set("redirect_uri", redirectURI)
	form.Set("state", state)
	form.Set("nonce", nonce)
	form.Set("scope", "openid profile email offline_access")
	form.Set("code_challenge", codeChallenge)
	form.Set("code_challenge_method", "S256")
	form.Set("dpop_jkt", dpop.jkt)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("client_assertion", assertion)
	req, _ := http.NewRequestWithContext(ctx, "POST", o.endpoints.PAREndpoint, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := o.hc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 201 {
		buf, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("PAR %d: %s", resp.StatusCode, string(buf))
	}
	var r struct {
		RequestURI string `json:"request_uri"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return "", err
	}
	return r.RequestURI, nil
}

// exchange performs the code-for-tokens exchange with DPoP proof header.
func (o *oidcClient) exchange(ctx context.Context, dpop *dpopSigner, redirectURI, code, codeVerifier string) (tokenResp, error) {
	assertion, err := o.clientAssertion(o.endpoints.TokenEndpoint)
	if err != nil {
		return tokenResp{}, err
	}
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	form.Set("client_id", o.cfg.KCClientID)
	form.Set("code_verifier", codeVerifier)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("client_assertion", assertion)
	return o.tokenCall(ctx, dpop, form)
}

// refresh redeems a refresh token. Refresh tokens MUST NOT be DPoP-bound
// (Keycloak client config), so this works after a BFF pod restart even
// though the dpop keypair changed.
func (o *oidcClient) refresh(ctx context.Context, dpop *dpopSigner, refreshToken string) (tokenResp, error) {
	assertion, err := o.clientAssertion(o.endpoints.TokenEndpoint)
	if err != nil {
		return tokenResp{}, err
	}
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", refreshToken)
	form.Set("client_id", o.cfg.KCClientID)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("client_assertion", assertion)
	return o.tokenCall(ctx, dpop, form)
}

// revoke is best-effort RFC 7009. Failure is logged, not surfaced.
func (o *oidcClient) revoke(ctx context.Context, refreshToken string) {
	assertion, err := o.clientAssertion(o.endpoints.RevocationEndpoint)
	if err != nil {
		slog.Warn("revoke assertion failed", "err", err)
		return
	}
	form := url.Values{}
	form.Set("token", refreshToken)
	form.Set("token_type_hint", "refresh_token")
	form.Set("client_id", o.cfg.KCClientID)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("client_assertion", assertion)
	req, _ := http.NewRequestWithContext(ctx, "POST", o.endpoints.RevocationEndpoint, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := o.hc.Do(req)
	if err != nil {
		slog.Warn("revoke call failed", "err", err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		slog.Warn("revoke non-200", "status", resp.StatusCode)
	}
}

type tokenResp struct {
	AccessToken      string `json:"access_token"`
	RefreshToken     string `json:"refresh_token"`
	IDToken          string `json:"id_token"`
	TokenType        string `json:"token_type"` // expect "DPoP"
	ExpiresIn        int    `json:"expires_in"`
	RefreshExpiresIn int    `json:"refresh_expires_in"`
	Scope            string `json:"scope"`
}

func (o *oidcClient) tokenCall(ctx context.Context, dpop *dpopSigner, form url.Values) (tokenResp, error) {
	var tr tokenResp
	proof, err := dpop.proofFor("POST", o.endpoints.TokenEndpoint, "")
	if err != nil {
		return tr, err
	}
	req, _ := http.NewRequestWithContext(ctx, "POST", o.endpoints.TokenEndpoint, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("DPoP", proof)
	resp, err := o.hc.Do(req)
	if err != nil {
		return tr, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		buf, _ := io.ReadAll(resp.Body)
		return tr, fmt.Errorf("token endpoint %d: %s", resp.StatusCode, string(buf))
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return tr, err
	}
	return tr, nil
}

// pkceVerifier returns a 43-char URL-safe random verifier and its
// S256 challenge.
func pkceVerifier() (verifier, challenge string, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return
	}
	verifier = base64.RawURLEncoding.EncodeToString(b)
	sum := sha256.Sum256([]byte(verifier))
	challenge = base64.RawURLEncoding.EncodeToString(sum[:])
	return
}

func parseRSAPriv(p []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(p)
	if block == nil {
		return nil, errors.New("not a PEM block")
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	any, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	rsaKey, ok := any.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an RSA private key")
	}
	return rsaKey, nil
}
