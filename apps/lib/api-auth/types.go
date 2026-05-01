package apiauth

import (
	"context"
	"crypto"
	"io"
	"net/http"
	"time"
)

// Claims is the validated subset of an inbound user-tier JWT that the library
// surfaces to callers. Returned by Middleware.ValidateInbound on success.
//
// Field set is fixed by ADR-0014 § Library API surface. Callers MUST treat
// Sub as opaque and MUST NOT log it directly (use a hash if a stable
// log-correlation key is needed).
type Claims struct {
	// Sub is the OIDC `sub` claim — the stable user identifier from Keycloak.
	Sub string

	// Aud is the JWT `aud` claim, normalized to a slice. JWT spec allows a
	// single string or an array; both shapes land here as a slice.
	Aud []string

	// RealmRoles is Keycloak's `realm_access.roles` claim, flattened. May be
	// empty if the user has no realm roles assigned.
	RealmRoles []string

	// SPIFFEID is the SPIFFE-SVID extracted from the inbound mTLS peer
	// certificate, if present. Nil when the request did not arrive over an
	// mTLS-authenticated connection (e.g., browser → Istio ingress hop).
	SPIFFEID *string

	// DPoPThumbprint is the JWS thumbprint of the DPoP-binding key, taken
	// from the JWT's `cnf.jkt` claim. Middleware verifies the inbound DPoP
	// proof's signing key matches this value.
	DPoPThumbprint string
}

// MiddlewareConfig is passed to NewMiddleware. All required fields must be
// non-zero; the library does not load defaults from environment or files.
//
// Per ADR-0014 § Per-API audience validation contract, ExpectedAudience is a
// single string per Middleware instance. Services that accept multiple
// audiences MUST construct multiple Middlewares, one per accept-path.
type MiddlewareConfig struct {
	// Issuer is the OIDC issuer URL the JWT's `iss` claim must equal
	// (e.g. "https://keycloak.secforge.local/realms/secforge").
	Issuer string

	// ExpectedAudience is the single audience this Middleware accepts. Tokens
	// whose `aud` does not contain this value are rejected with
	// ErrAudienceMismatch.
	ExpectedAudience string

	// JWKSEndpoint is the JWKS URL used to fetch the issuer's signing keys.
	// The Middleware caches keys locally and refreshes on `kid` miss.
	JWKSEndpoint string

	// ReplayCache backs DPoP `jti` replay protection. Required.
	ReplayCache ReplayCache

	// HTTPClient is used for JWKS fetches. Optional; defaults to
	// http.DefaultClient.
	HTTPClient *http.Client

	// Clock is the time source used for `exp`/`nbf`/`iat` validation.
	// Optional; defaults to time.Now.
	Clock func() time.Time
}

// ClientConfig is passed to NewClient. Per ADR-0014 § Library API surface,
// Client.MintTokenForAudience consults SessionStore for cached tokens and
// only contacts Keycloak when a refresh-with-expanded-scope is required.
type ClientConfig struct {
	// TokenEndpoint is Keycloak's token URL.
	TokenEndpoint string

	// ClientID is this BFF's Keycloak client identifier.
	ClientID string

	// ClientAssertionPEM is the BFF's already-loaded private_key_jwt PEM.
	// Caller is responsible for sourcing this from OpenBao via the secrets
	// package (ADR-0019); the library does not read it from disk.
	ClientAssertionPEM []byte

	// AudienceList is the static BFF_AUDIENCE_LIST per Q2: requests for an
	// audience not in this list short-circuit to ErrAudienceNotConfigured
	// without ever touching Keycloak.
	AudienceList []string

	// SessionStore is the user-session token cache (Valkey-backed in
	// production). Required.
	SessionStore SessionStore

	// DPoPKey is the BFF's per-pod ECDSA P-256 key (per ADR-0011); the
	// minted access token is bound to its JWS thumbprint via `cnf.jkt`.
	DPoPKey crypto.Signer

	// HTTPClient is used for Keycloak refresh calls. Optional; defaults to
	// http.DefaultClient.
	HTTPClient *http.Client

	// Clock is the time source used for cached-token expiry checks.
	// Optional; defaults to time.Now.
	Clock func() time.Time
}

// AuditConfig is passed to NewAudit. Audit.LogHop emits one JSON line per
// hop to Writer; a write timeout caps how long a slow log sink can block a
// request path.
type AuditConfig struct {
	// Writer is the audit-log sink. Typically os.Stdout (Promtail tails
	// container stdout to Loki). Required.
	Writer io.Writer

	// Clock is the time source for the `timestamp` field. Optional; defaults
	// to time.Now.
	Clock func() time.Time

	// WriteTimeout caps a single LogHop call. If the underlying Writer does
	// not complete within this window, LogHop drops the line and returns an
	// error rather than block the request path. Optional; defaults to 100ms.
	WriteTimeout time.Duration
}

// ReplayCache atomically detects DPoP `jti` replay within a sliding window.
// Implementations MUST be safe for concurrent use.
//
// Section 3 of phase-06b-api-pattern.md ships an in-memory implementation
// for tests; production wires Valkey behind this interface.
type ReplayCache interface {
	// SeenWithin returns true if jti was already inserted within window. The
	// implementation MUST insert jti atomically so that a concurrent caller
	// observes true on the second call. Returns a non-nil error only on
	// transport / store failure; absent-jti is (false, nil).
	SeenWithin(ctx context.Context, jti string, window time.Duration) (bool, error)
}

// SessionStore is the user-session token cache that backs Client.MintTokenForAudience.
// Backed by Valkey in production (Phase 6 BFF session store).
type SessionStore interface {
	// GetSession returns the session token bundle for sessionKey. Returns
	// a nil bundle and nil error if the session is absent — distinguishes
	// "no session" from transport errors.
	GetSession(ctx context.Context, sessionKey string) (*SessionTokens, error)

	// PutSession persists an updated bundle, typically after a refresh
	// expanded the audience set.
	PutSession(ctx context.Context, sessionKey string, tokens *SessionTokens) error
}

// SessionTokens is the bundle of OAuth tokens plus the audience set the
// access token currently carries. Stored per user session.
type SessionTokens struct {
	AccessToken  string
	RefreshToken string
	ExpiresAt    time.Time
	Audiences    []string
}
