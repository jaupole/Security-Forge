package apiauth

import "errors"

// Sentinel errors returned by Middleware.ValidateInbound and
// Client.MintTokenForAudience. Each carries a canonical HTTP mapping per
// ADR-0014 § Error-handling contract; callers translate these to HTTP
// responses but the library itself never writes a response.
//
// Use errors.Is to test for these — implementations may wrap a sentinel
// with additional context via fmt.Errorf("%w: ...", ErrInvalidToken).

// ErrInvalidToken — JWT failed structural / signature / iss validation.
// HTTP 401. Reject; do not retry.
var ErrInvalidToken = errors.New("apiauth: invalid token")

// ErrTokenExpired — JWT `exp` is in the past (with Clock skew applied).
// HTTP 401. Reject; client should refresh.
var ErrTokenExpired = errors.New("apiauth: token expired")

// ErrAudienceMismatch — JWT `aud` does not contain the Middleware's
// ExpectedAudience. HTTP 401. Suggests the caller used a token minted for
// a different service.
var ErrAudienceMismatch = errors.New("apiauth: audience mismatch")

// ErrDPoPMissing — protected request arrived without a DPoP proof header.
// HTTP 401. Client should retry with a DPoP proof.
var ErrDPoPMissing = errors.New("apiauth: DPoP proof missing")

// ErrDPoPMismatch — DPoP proof present but its signing key does not match
// the JWT's `cnf.jkt`, or its `htu`/`htm`/`jti` failed validation.
// HTTP 401. Suggests pod roll or replay attempt.
var ErrDPoPMismatch = errors.New("apiauth: DPoP proof mismatch")

// ErrAudienceNotConfigured — Client.MintTokenForAudience called for an
// audience absent from ClientConfig.AudienceList. HTTP 500: this means the
// BFF's own static config is wrong. Alert and fail loud — never retry.
var ErrAudienceNotConfigured = errors.New("apiauth: audience not configured in BFF_AUDIENCE_LIST")

// ErrAudienceUnavailable — Keycloak rejected a refresh-with-expanded-scope
// (Q3 fallback). HTTP 401 plus Set-Cookie clearing the session plus
// Location: /login; the user re-authenticates.
var ErrAudienceUnavailable = errors.New("apiauth: audience unavailable for this session")

// ErrKeycloakUnreachable — transport-level failure talking to Keycloak
// (timeout, TCP reset, 5xx). HTTP 502. Transient; safe to retry.
var ErrKeycloakUnreachable = errors.New("apiauth: keycloak unreachable")
