package secrets

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// OpenBaoBootstrapper is the OpenBao adapter for SecretBootstrapper.
//
// Auth path: SPIRE writes a JWT-SVID to a file inside the pod (the
// `spiffe-helper` init container handles this); the bootstrapper reads
// it, exchanges via OpenBao's auth/jwt/login endpoint for a short-lived
// client token, then performs the KV-v2 read.
//
// One full login + read per Get call. Token is not cached — on
// startup-only (the BFF's case) this is the right tradeoff (simpler,
// no expiry handling). Apps that need many reads should batch via
// caller-side caching.
//
// Construct via NewOpenBaoBootstrapper. The struct is unexported
// intentionally; consumers hold the SecretBootstrapper interface.
type OpenBaoBootstrapper struct {
	addr         string
	jwtPath      string
	role         string
	clientKVPath string
	hc           *http.Client
}

// NewOpenBaoBootstrapper creates an OpenBao-backed SecretBootstrapper.
//
// Arguments:
//   - addr:         OpenBao base URL (e.g. https://openbao.openbao.svc:8200)
//   - jwtPath:      path inside the pod where the SPIFFE JWT-SVID is written
//                   (e.g. /shared/openbao.jwt — written by spiffe-helper)
//   - role:         OpenBao auth/jwt role bound to the SPIFFE-ID (e.g.
//                   "helloworld-bff")
//   - clientKVPath: KV-v2 path for the per-app client key (e.g.
//                   "secret/data/keycloak/clients/helloworld-bff")
//
// The HTTP client uses the system trust store (which the BFF image bundles
// the mkcert local CA into at build time, per Phase 6.7). 10-second
// timeout per call.
func NewOpenBaoBootstrapper(addr, jwtPath, role, clientKVPath string) (SecretBootstrapper, error) {
	if addr == "" {
		return nil, errors.New("openbao addr required")
	}
	if jwtPath == "" {
		return nil, errors.New("jwtPath required")
	}
	if role == "" {
		return nil, errors.New("role required")
	}
	if clientKVPath == "" {
		return nil, errors.New("clientKVPath required")
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
	return &OpenBaoBootstrapper{
		addr:         addr,
		jwtPath:      jwtPath,
		role:         role,
		clientKVPath: clientKVPath,
		hc:           hc,
	}, nil
}

// GetClientKey reads the constructor-configured clientKVPath and returns
// the `private_pem` field's value as bytes. Errors include the path but
// never the value.
func (b *OpenBaoBootstrapper) GetClientKey(ctx context.Context) ([]byte, error) {
	tok, err := b.login(ctx)
	if err != nil {
		return nil, fmt.Errorf("openbao login: %w", err)
	}
	pem, err := b.kvReadField(ctx, tok, b.clientKVPath, "private_pem")
	if err != nil {
		return nil, fmt.Errorf("openbao kv read %s: %w", b.clientKVPath, err)
	}
	return pem, nil
}

// GetKV reads an arbitrary KV-v2 path (the role's policy must permit it)
// and returns the entire data object as JSON bytes. Callers that want a
// specific field should JSON-decode and pluck.
//
// The path argument is the KV-v2 API path including the "secret/data/"
// prefix (e.g. "secret/data/apps/foo/bar"). The /v1/ HTTP prefix is
// added automatically.
func (b *OpenBaoBootstrapper) GetKV(ctx context.Context, path string) ([]byte, error) {
	if path == "" {
		return nil, errors.New("path required")
	}
	tok, err := b.login(ctx)
	if err != nil {
		return nil, fmt.Errorf("openbao login: %w", err)
	}
	return b.kvReadRaw(ctx, tok, path)
}

// ─── internal HTTP plumbing ──────────────────────────────────────────

func (b *OpenBaoBootstrapper) login(ctx context.Context) (string, error) {
	jwtBytes, err := os.ReadFile(b.jwtPath)
	if err != nil {
		return "", fmt.Errorf("read JWT-SVID at %s: %w", b.jwtPath, err)
	}
	body := map[string]string{"role": b.role, "jwt": string(jwtBytes)}
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", b.addr+"/v1/auth/jwt/login", bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	resp, err := b.hc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("login %d: %s", resp.StatusCode, string(errBody))
	}
	var r struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return "", err
	}
	if r.Auth.ClientToken == "" {
		return "", errors.New("empty client_token")
	}
	return r.Auth.ClientToken, nil
}

func (b *OpenBaoBootstrapper) kvReadField(ctx context.Context, tok, path, field string) ([]byte, error) {
	raw, err := b.kvReadRaw(ctx, tok, path)
	if err != nil {
		return nil, err
	}
	var r struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("decode KV response: %w", err)
	}
	val, ok := r.Data.Data[field]
	if !ok || val == "" {
		// Don't include `field` in case of accidental data echo;
		// the path tells the operator enough.
		return nil, fmt.Errorf("required field missing in KV value at %s", path)
	}
	return []byte(val), nil
}

func (b *OpenBaoBootstrapper) kvReadRaw(ctx context.Context, tok, path string) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", b.addr+"/v1/"+path, nil)
	req.Header.Set("X-Vault-Token", tok)
	resp, err := b.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("kv read %d: %s", resp.StatusCode, string(errBody))
	}
	return io.ReadAll(resp.Body)
}

func systemRootsOrEmpty() *x509.CertPool {
	p, _ := x509.SystemCertPool()
	if p == nil {
		p = x509.NewCertPool()
	}
	return p
}
