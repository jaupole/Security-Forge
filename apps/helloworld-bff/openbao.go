package main

// SPIRE-issued JWT-SVID -> OpenBao auth/jwt -> KV-v2 read.
//
// The init container (spiffe-helper) writes the JWT-SVID at
// c.OpenBaoSVIDIn. We exchange it for a short-lived OpenBao token via
// the `helloworld-bff` jwt-auth role, then read the BFF's
// private_key_jwt PEM from secret/data/keycloak/clients/helloworld-bff.
//
// On startup only — never refreshed in-process. Pod restart re-runs.

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func bootstrapClientKey(ctx context.Context, c cfg) ([]byte, error) {
	jwt, err := os.ReadFile(c.OpenBaoSVIDIn)
	if err != nil {
		return nil, fmt.Errorf("read JWT-SVID: %w", err)
	}
	hc := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			// In-cluster TLS chain is mkcert-signed; the BFF image carries
			// the mkcert root as a system trust anchor (Phase 6.7 step).
			// We still allow override via empty pool fallback for now.
			TLSClientConfig: &tls.Config{
				MinVersion: tls.VersionTLS12,
				RootCAs:    systemRootsOrEmpty(),
			},
		},
	}
	tok, err := openBaoLogin(ctx, hc, c.OpenBaoAddr, c.OpenBaoRole, string(jwt))
	if err != nil {
		return nil, fmt.Errorf("openbao login: %w", err)
	}
	pem, err := openBaoKVRead(ctx, hc, c.OpenBaoAddr, tok, c.OpenBaoKVPath)
	if err != nil {
		return nil, fmt.Errorf("openbao kv read: %w", err)
	}
	return pem, nil
}

func openBaoLogin(ctx context.Context, hc *http.Client, addr, role, jwt string) (string, error) {
	body := map[string]string{"role": role, "jwt": jwt}
	b, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", addr+"/v1/auth/jwt/login", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		buf, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("login %d: %s", resp.StatusCode, string(buf))
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
		return "", fmt.Errorf("empty client_token")
	}
	return r.Auth.ClientToken, nil
}

func openBaoKVRead(ctx context.Context, hc *http.Client, addr, tok, path string) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", addr+"/v1/"+path, nil)
	req.Header.Set("X-Vault-Token", tok)
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		buf, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("kv read %d: %s", resp.StatusCode, string(buf))
	}
	var r struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	pem, ok := r.Data.Data["private_pem"]
	if !ok || pem == "" {
		return nil, fmt.Errorf("private_pem missing in KV value")
	}
	return []byte(pem), nil
}

func systemRootsOrEmpty() *x509.CertPool {
	p, _ := x509.SystemCertPool()
	if p == nil {
		p = x509.NewCertPool()
	}
	return p
}
