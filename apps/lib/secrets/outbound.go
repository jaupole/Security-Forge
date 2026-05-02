package secrets

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Config configures an outbound-secrets Client.
//
// AppName MUST match the SPIFFE-ID short name bound to the OpenBao
// templated role (e.g., "proposal-forge", "helloworld-bff"). The path
// scheme is `secret/data/apps/<AppName>/<integration>` per ADR-0013 § 1.
//
// Hardened defaults to true for new apps per ADR-0013 § 7. The
// non-Hardened path is documented-deferred until the first existing
// app is onboarded — at which point a sibling GetFieldString method
// will be added gated on Hardened == false.
type Config struct {
	AppName  string
	CacheTTL time.Duration
	Hardened bool
}

// Client is the outbound-secrets API for first-class apps. It fetches
// static third-party credentials from OpenBao at runtime via the
// SecretBootstrapper supplied at construction. Concurrent-safe; one
// Client per app, shared across goroutines.
//
// See ADR-0013 for the policy this Client enforces and ADR-0019 for
// the SecretBootstrapper interface this Client composes.
type Client struct {
	bs       SecretBootstrapper
	appName  string
	cache    *kvCache
	hardened bool
}

// New constructs a Client. The SecretBootstrapper is supplied by the
// caller (typically from NewOpenBaoBootstrapper); tests pass a fake.
// Config.AppName is required; CacheTTL defaults to 5m if zero.
func New(bs SecretBootstrapper, cfg Config) (*Client, error) {
	if bs == nil {
		return nil, errors.New("secrets.New: bootstrapper required")
	}
	if cfg.AppName == "" {
		return nil, errors.New("secrets.New: AppName required")
	}
	return &Client{
		bs:       bs,
		appName:  cfg.AppName,
		cache:    newKVCache(cfg.CacheTTL),
		hardened: cfg.Hardened,
	}, nil
}

// GetField returns the named field at the per-integration KV path
// `secret/data/apps/<AppName>/<integration>`, wrapped in a Secret.
// Cache hits skip the OpenBao roundtrip; misses fetch the integration's
// full KV value, populate the cache, then return the requested field.
//
// Errors include the integration and field names but never the secret
// value. Callers MUST consume the returned Secret via Use or one of
// its helpers (HTTPHeader, BasicAuth, DSN) per ADR-0013 § 7.
func (c *Client) GetField(ctx context.Context, integration, field string) (Secret, error) {
	if integration == "" {
		return Secret{}, errors.New("integration required")
	}
	if field == "" {
		return Secret{}, errors.New("field required")
	}
	path := fmt.Sprintf("secret/data/apps/%s/%s", c.appName, integration)

	data, hit := c.cache.get(path)
	if !hit {
		raw, err := c.bs.GetKV(ctx, path)
		if err != nil {
			return Secret{}, fmt.Errorf("openbao read integration=%s: %w", integration, err)
		}
		decoded, err := decodeKVData(raw)
		if err != nil {
			return Secret{}, fmt.Errorf("openbao decode integration=%s: %w", integration, err)
		}
		c.cache.put(path, decoded)
		data = decoded
	}
	val, ok := data[field]
	if !ok || val == "" {
		return Secret{}, fmt.Errorf("field %q not present at integration=%s", field, integration)
	}
	// Copy into a fresh slice so Secret.Use's zeroing doesn't corrupt
	// the cached map's underlying string data.
	buf := make([]byte, len(val))
	copy(buf, val)
	return NewSecret(buf), nil
}

// Close clears the cache. Best-effort; Go strings are immutable so the
// underlying byte storage isn't reclaimed until GC, but cached entries
// become unreachable from the Client.
func (c *Client) Close() {
	c.cache.clear()
}

// decodeKVData parses an OpenBao KV-v2 response body and returns the
// inner data.data map. KV-v2 responses are double-nested:
//
//	{"data": {"data": {"<field>": "<value>", ...}, "metadata": {...}}}
func decodeKVData(raw []byte) (map[string]string, error) {
	var r struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("decode KV response: %w", err)
	}
	if r.Data.Data == nil {
		return nil, errors.New("KV response has no data field")
	}
	return r.Data.Data, nil
}
