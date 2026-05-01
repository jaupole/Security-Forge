package apiauth

import (
	"errors"
	"net/http"
)

// Middleware validates inbound user-tier JWT+DPoP requests against
// Keycloak's JWKS and the configured audience. See ADR-0014 § Library API
// surface. Construct via NewMiddleware; one Middleware instance accepts a
// single audience.
type Middleware struct {
	cfg MiddlewareConfig
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
// Skeleton implementation lands in commit 2 of Phase 6b-1; this stub returns
// a non-sentinel error so any accidental early caller fails loudly.
func (m *Middleware) ValidateInbound(req *http.Request) (*Claims, error) {
	return nil, errors.New("apiauth: ValidateInbound not yet implemented (skeleton)")
}
