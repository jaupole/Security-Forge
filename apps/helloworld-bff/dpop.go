package main

// DPoP (RFC 9449) proof minting + htu canonicalization.
//
// Per the BFF design doc:
//   * keypair: ECDSA P-256, generated once at startup, in-memory only.
//   * jkt: RFC 7638 thumbprint over the JWK form, base64url SHA-256.
//   * htu canonicalization rule (single source of truth):
//       lowercase(scheme) "://" lowercase(host) [":port-if-non-default"] path
//       — no query, no fragment, no userinfo
//   * outbound proof carries htm/htu/iat/jti/ath; ath = b64url(SHA-256(access_token)).
//   * inbound: BFF rejects requests missing X-Forwarded-Proto/Host (no fallback to r.Host).

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/lestrrat-go/jwx/v2/jwt"
)

type dpopSigner struct {
	priv    *ecdsa.PrivateKey
	pubJWK  jwk.Key // public-key half, ready for the proof header
	jkt     string  // RFC 7638 thumbprint
}

func newDPoP() (*dpopSigner, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	pub, err := jwk.FromRaw(&priv.PublicKey)
	if err != nil {
		return nil, err
	}
	if err := pub.Set(jwk.AlgorithmKey, jwa.ES256); err != nil {
		return nil, err
	}
	if err := pub.Set(jwk.KeyUsageKey, "sig"); err != nil {
		return nil, err
	}
	tp, err := pub.Thumbprint(crypto.SHA256)
	if err != nil {
		return nil, err
	}
	jkt := base64.RawURLEncoding.EncodeToString(tp)
	return &dpopSigner{priv: priv, pubJWK: pub, jkt: jkt}, nil
}

// canonicalHTU implements the rule from docs/01-architecture/04-bff-pattern.md
// §"htu canonicalization rule". Single source of truth; every proof site
// goes through here.
func canonicalHTU(rawURL string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	if u.Scheme == "" || u.Host == "" {
		return "", fmt.Errorf("htu: scheme/host required, got %q", rawURL)
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())
	port := u.Port()
	if (scheme == "https" && port == "443") || (scheme == "http" && port == "80") {
		port = ""
	}
	hostport := host
	if port != "" {
		hostport = host + ":" + port
	}
	path := u.Path
	if path == "" {
		path = "/"
	}
	return scheme + "://" + hostport + path, nil
}

// inboundHTU builds the canonical htu of the *incoming* request from
// trusted forwarded headers. Fail-closed on missing headers — see the
// design doc fail-closed clause and CLAUDE.md gotcha #3.
func inboundHTU(r *http.Request) (string, error) {
	proto := r.Header.Get("X-Forwarded-Proto")
	host := r.Header.Get("X-Forwarded-Host")
	if proto == "" || host == "" {
		return "", errors.New("missing X-Forwarded-Proto or X-Forwarded-Host")
	}
	return canonicalHTU(proto + "://" + host + r.URL.Path)
}

// proofFor mints a DPoP proof JWT for an outbound request. The caller
// must pass the actual request URL (so htu reflects what's on the wire,
// not what we wish was on the wire). When `accessToken` is non-empty,
// the `ath` claim is included (RFC 9449 §4.3) — required when the proof
// accompanies an access-token presentation.
func (d *dpopSigner) proofFor(method, rawURL, accessToken string) (string, error) {
	htu, err := canonicalHTU(rawURL)
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	t := jwt.New()
	_ = t.Set("htm", strings.ToUpper(method))
	_ = t.Set("htu", htu)
	_ = t.Set("iat", now.Unix())
	_ = t.Set("jti", uuid.NewString())
	if accessToken != "" {
		sum := sha256.Sum256([]byte(accessToken))
		_ = t.Set("ath", base64.RawURLEncoding.EncodeToString(sum[:]))
	}

	hdrs := jws.NewHeaders()
	_ = hdrs.Set(jws.TypeKey, "dpop+jwt")
	_ = hdrs.Set(jws.JWKKey, d.pubJWK)

	signed, err := jwt.Sign(t, jwt.WithKey(jwa.ES256, d.priv, jws.WithProtectedHeaders(hdrs)))
	if err != nil {
		return "", err
	}
	return string(signed), nil
}
