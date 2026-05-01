package apiauth

import (
	"context"
	"errors"
)

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

// MintTokenForAudience returns a JWT bound to the BFF's per-pod DPoP key
// with the requested audience as the target. The session-key the Client
// uses to look up cached tokens is read from the context via a key the
// BFF sets before calling — Section 4 of phase-06b-api-pattern.md fixes
// the exact context-key convention.
//
// Returns ErrAudienceNotConfigured immediately if aud is not in
// ClientConfig.AudienceList. See errors.go for the full error contract.
//
// Implementation lands in commit 3 of Phase 6b-1.
func (c *Client) MintTokenForAudience(ctx context.Context, aud string) (string, error) {
	return "", errors.New("apiauth: MintTokenForAudience not yet implemented (skeleton)")
}
