package secrets

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// TransitClient encrypts and decrypts field values via OpenBao's Transit
// secrets engine. Use it to keep PII (emails, names, addresses, free-text
// notes) ciphertext-at-rest in Postgres without giving the app
// long-lived static keys.
//
// Auth: same JWT-SVID flow as OpenBaoBootstrapper (SPIRE writes the
// JWT-SVID to a file, this client reads it, exchanges for a short-lived
// OpenBao token via auth/jwt/login, then calls transit/encrypt/<key> or
// transit/decrypt/<key>).
//
// The OpenBao token is cached in-memory and refreshed when it returns
// 403 (treated as expired) — the bootstrapper's "one login per call"
// pattern is too chatty for per-row encrypt/decrypt. TTL is read from
// the auth response and a 30-second safety margin is applied.
//
// Construct via NewTransitClient. The returned struct is exported so
// callers can pass it as either Encrypter or Decrypter (handy for
// dependency injection / testing).
type TransitClient struct {
	addr    string
	jwtPath string
	role    string
	keyName string
	hc      *http.Client

	mu      sync.Mutex
	token   string
	expires time.Time
}

// Encrypter encrypts plaintext bytes. ciphertext is OpenBao's
// `vault:v<n>:<base64>` format — store this verbatim; do NOT trim or
// normalize, the version prefix is required for key rotation to work.
type Encrypter interface {
	Encrypt(ctx context.Context, plaintext []byte) (ciphertext string, err error)
}

// Decrypter decrypts an OpenBao-format ciphertext and returns it
// wrapped in a Secret so callers must use Use(...) to access the
// plaintext bytes (see secret.go).
type Decrypter interface {
	Decrypt(ctx context.Context, ciphertext string) (Secret, error)
}

// NewTransitClient creates a Transit-backed encrypt/decrypt client.
//
// Arguments:
//   - addr:    OpenBao base URL (e.g. https://openbao.openbao.svc:8200)
//   - jwtPath: path inside the pod where the SPIFFE JWT-SVID is written
//             (the spiffe-helper init container handles this; it MUST
//             be the same JWT path the rest of the app uses)
//   - role:   OpenBao auth/jwt role bound to this app's SPIFFE-ID
//   - keyName: Transit key name (e.g. "pii-encryption" — the platform
//             default; per-app keys are also supported, just provision
//             them in advance)
//
// The role's policy MUST grant `update` on `transit/encrypt/<keyName>`
// and `transit/decrypt/<keyName>`. The platform-shared `pii-encryption`
// key + the helloworld-bff policy demonstrate the pattern.
//
// HTTP client uses the system trust store + 10s timeout per call. For
// high-throughput callers consider batching via Transit's
// /encrypt/<key>/batch endpoint (not exposed by this client yet — open
// an issue if you need it).
func NewTransitClient(addr, jwtPath, role, keyName string) (*TransitClient, error) {
	if addr == "" {
		return nil, errors.New("transit: addr required")
	}
	if jwtPath == "" {
		return nil, errors.New("transit: jwtPath required")
	}
	if role == "" {
		return nil, errors.New("transit: role required")
	}
	if keyName == "" {
		return nil, errors.New("transit: keyName required")
	}
	hc := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				MinVersion: tls.VersionTLS12,
				RootCAs:    systemRootsOrEmpty(),
			},
		},
	}
	return &TransitClient{
		addr:    addr,
		jwtPath: jwtPath,
		role:    role,
		keyName: keyName,
		hc:      hc,
	}, nil
}

// Encrypt POSTs plaintext (base64-encoded per Transit's API) to
// transit/encrypt/<keyName> and returns the OpenBao-format ciphertext
// `vault:v<n>:<base64>`. The plaintext slice is NOT zeroed by this
// method — callers passing a Secret should do `s.Use(func(b) error {
// ct, err := c.Encrypt(ctx, b); ... })` so the bytes get zeroed by
// Use's defer chain.
func (c *TransitClient) Encrypt(ctx context.Context, plaintext []byte) (string, error) {
	if len(plaintext) == 0 {
		return "", errors.New("transit: empty plaintext")
	}
	tok, err := c.tokenFor(ctx)
	if err != nil {
		return "", err
	}
	body := map[string]string{"plaintext": base64.StdEncoding.EncodeToString(plaintext)}
	buf, _ := json.Marshal(body)
	path := "/v1/transit/encrypt/" + c.keyName
	req, _ := http.NewRequestWithContext(ctx, "POST", c.addr+path, bytes.NewReader(buf))
	req.Header.Set("X-Vault-Token", tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("transit encrypt: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 403 {
		c.invalidateToken()
		return "", errors.New("transit encrypt: 403 (token expired or policy denies)")
	}
	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("transit encrypt %d: %s", resp.StatusCode, string(errBody))
	}
	var r struct {
		Data struct {
			Ciphertext string `json:"ciphertext"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return "", fmt.Errorf("transit encrypt decode: %w", err)
	}
	if !strings.HasPrefix(r.Data.Ciphertext, "vault:v") {
		return "", errors.New("transit encrypt: ciphertext missing vault:v<n>: prefix")
	}
	return r.Data.Ciphertext, nil
}

// Decrypt POSTs ciphertext to transit/decrypt/<keyName> and returns the
// recovered plaintext wrapped in a Secret. Callers MUST access the
// bytes via Secret.Use, which zeroes the buffer after use.
//
// Ciphertext must include the `vault:v<n>:` prefix (which OpenBao adds
// on Encrypt). Stripping the prefix is a common bug — don't.
func (c *TransitClient) Decrypt(ctx context.Context, ciphertext string) (Secret, error) {
	if !strings.HasPrefix(ciphertext, "vault:v") {
		return Secret{}, errors.New("transit: ciphertext missing vault:v<n>: prefix")
	}
	tok, err := c.tokenFor(ctx)
	if err != nil {
		return Secret{}, err
	}
	body := map[string]string{"ciphertext": ciphertext}
	buf, _ := json.Marshal(body)
	path := "/v1/transit/decrypt/" + c.keyName
	req, _ := http.NewRequestWithContext(ctx, "POST", c.addr+path, bytes.NewReader(buf))
	req.Header.Set("X-Vault-Token", tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return Secret{}, fmt.Errorf("transit decrypt: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 403 {
		c.invalidateToken()
		return Secret{}, errors.New("transit decrypt: 403 (token expired or policy denies)")
	}
	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		return Secret{}, fmt.Errorf("transit decrypt %d: %s", resp.StatusCode, string(errBody))
	}
	var r struct {
		Data struct {
			Plaintext string `json:"plaintext"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return Secret{}, fmt.Errorf("transit decrypt decode: %w", err)
	}
	pt, err := base64.StdEncoding.DecodeString(r.Data.Plaintext)
	if err != nil {
		return Secret{}, fmt.Errorf("transit decrypt b64: %w", err)
	}
	return NewSecret(pt), nil
}

// ─── token lifecycle ─────────────────────────────────────────────────

// tokenFor returns a cached OpenBao token if still fresh, otherwise
// performs a JWT-SVID login. Concurrent callers serialize on the mutex
// during refresh — the per-call cost is negligible compared to the
// HTTP round-trip.
func (c *TransitClient) tokenFor(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.expires) {
		return c.token, nil
	}
	tok, ttl, err := c.login(ctx)
	if err != nil {
		return "", err
	}
	c.token = tok
	// 30-second safety margin so the token doesn't expire mid-call.
	c.expires = time.Now().Add(ttl - 30*time.Second)
	return tok, nil
}

func (c *TransitClient) invalidateToken() {
	c.mu.Lock()
	c.token = ""
	c.expires = time.Time{}
	c.mu.Unlock()
}

func (c *TransitClient) login(ctx context.Context) (token string, ttl time.Duration, err error) {
	jwtBytes, err := os.ReadFile(c.jwtPath)
	if err != nil {
		return "", 0, fmt.Errorf("transit login: read JWT-SVID at %s: %w", c.jwtPath, err)
	}
	body := map[string]string{"role": c.role, "jwt": string(jwtBytes)}
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", c.addr+"/v1/auth/jwt/login", bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		return "", 0, fmt.Errorf("transit login %d: %s", resp.StatusCode, string(errBody))
	}
	var r struct {
		Auth struct {
			ClientToken   string `json:"client_token"`
			LeaseDuration int    `json:"lease_duration"`
		} `json:"auth"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return "", 0, err
	}
	if r.Auth.ClientToken == "" {
		return "", 0, errors.New("transit login: empty client_token")
	}
	if r.Auth.LeaseDuration <= 0 {
		// Default to 1h if OpenBao doesn't supply one (shouldn't
		// happen with the standard k8s/jwt auth role config).
		r.Auth.LeaseDuration = 3600
	}
	return r.Auth.ClientToken, time.Duration(r.Auth.LeaseDuration) * time.Second, nil
}
