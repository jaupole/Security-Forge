package main

// auth.go wires the apps/lib/api-auth library into helloworld-bff. The
// library is the canonical implementation of Phase 6b-1's audience-at-login
// model (per ADR-0014); helloworld-bff is its first consumer.
//
// What lives here:
//   - bffSessionAdapter — bridges the BFF's sessionStore (sessionV1 shape)
//     to apiauth.SessionStore (SessionTokens shape) so apiauth.Client can
//     read/write session tokens without re-implementing Valkey access.
//   - newAPIAuth — constructs apiauth.Middleware + Client + Audit from
//     the BFF's existing config + the new BFF_AUDIENCE_LIST /
//     BFF_BACKEND_AUDIENCE / BFF_WORKLOAD_ID env vars.
//   - errToHTTP — maps apiauth typed errors back to the canonical HTTP
//     status + short slug for the proxy handler.
//
// Notes:
//   - apiauth.Middleware is constructed for completeness but not currently
//     wired into a route. The BFF authenticates inbound via session cookies
//     (not Bearer tokens); future Bearer-tier endpoints (e.g. M2M access
//     to a future BFF admin API) are the real consumers of Middleware.
//   - apiauth.Client is wired into proxy.go's proxyToBackend for the
//     /api/* outbound hop.
//   - apiauth.Audit emits the per-hop SPIFFE+request-id line at three
//     sites in proxy.go: inbound edge, outbound attempt, outbound result.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	apiauth "github.com/secforge/lib/api-auth"
)

// bffSessionAdapter satisfies apiauth.SessionStore by translating between
// the BFF's sessionV1 shape and apiauth's SessionTokens shape.
type bffSessionAdapter struct {
	inner *sessionStore
	jkt   string // current BFF DPoP key thumbprint — used to detect key roll
}

func newBFFSessionAdapter(inner *sessionStore, jkt string) *bffSessionAdapter {
	return &bffSessionAdapter{inner: inner, jkt: jkt}
}

func (a *bffSessionAdapter) GetSession(ctx context.Context, key string) (*apiauth.SessionTokens, error) {
	sv, err := a.inner.get(ctx, key)
	if err != nil {
		// Treat any error (redis.Nil, schema mismatch, transport) as "no
		// session" — the upper layer either retries via /login or surfaces
		// the error to the user. Distinguishing transient transport from
		// missing-key here would couple us to redis-specific error codes
		// which the lib wants to stay unaware of.
		return nil, nil
	}
	// Audiences set is the JWT's `aud` claim. We only trust it when the
	// session's DPoP-jkt-at-issue still matches the BFF's current pod-key:
	// after a key roll, the cached access token is no longer usable
	// regardless of expiry, and we want the apiauth.Client to take the
	// refresh path rather than return a stale token.
	auds := []string{}
	if sv.DPoPJktAtIssue == a.jkt {
		auds = decodeJWTAudienceClaim(sv.AccessToken)
	}
	return &apiauth.SessionTokens{
		AccessToken:  sv.AccessToken,
		RefreshToken: sv.RefreshToken,
		ExpiresAt:    time.Unix(sv.AccessExp, 0),
		Audiences:    auds,
	}, nil
}

func (a *bffSessionAdapter) PutSession(ctx context.Context, key string, t *apiauth.SessionTokens) error {
	sv, err := a.inner.get(ctx, key)
	if err != nil {
		// No prior session to update — nothing to do. The library's
		// audience-at-login refresh expects an existing session; if the
		// session vanished mid-flight, the next request hits /login.
		return nil
	}
	sv.AccessToken = t.AccessToken
	if t.RefreshToken != "" {
		sv.RefreshToken = t.RefreshToken
	}
	sv.AccessExp = t.ExpiresAt.Unix()
	sv.DPoPJktAtIssue = a.jkt
	return a.inner.put(ctx, key, sv)
}

// decodeJWTAudienceClaim parses the access-token's `aud` claim without
// verifying the signature. Used only to populate the SessionTokens.Audiences
// cache — apiauth.Middleware verifies signatures separately on each
// inbound request.
func decodeJWTAudienceClaim(accessToken string) []string {
	parts := strings.Split(accessToken, ".")
	if len(parts) < 2 {
		return nil
	}
	payload, err := base64URLDecode(parts[1])
	if err != nil {
		return nil
	}
	var claims struct {
		Aud interface{} `json:"aud"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil
	}
	switch v := claims.Aud.(type) {
	case string:
		return []string{v}
	case []interface{}:
		out := make([]string, 0, len(v))
		for _, x := range v {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

// apiAuthBundle is the trio of apps/lib/api-auth types the BFF consumes.
type apiAuthBundle struct {
	mw    *apiauth.Middleware
	cli   *apiauth.Client
	audit *apiauth.Audit

	workloadID      string
	backendAudience string
}

// newAPIAuth instantiates the bundle. The constructor reads the new
// env vars BFF_AUDIENCE_LIST, BFF_BACKEND_AUDIENCE, and BFF_WORKLOAD_ID
// directly (the rest reuses the BFF's existing cfg).
func newAPIAuth(c cfg, sess *sessionStore, dpop *dpopSigner, clientPriv []byte, jkt string) (*apiAuthBundle, error) {
	audList := splitCommaCSV(os.Getenv("BFF_AUDIENCE_LIST"))
	if len(audList) == 0 {
		return nil, errors.New("BFF_AUDIENCE_LIST not set or empty")
	}
	backendAud := os.Getenv("BFF_BACKEND_AUDIENCE")
	if backendAud == "" {
		return nil, errors.New("BFF_BACKEND_AUDIENCE not set")
	}
	if !sliceContains(audList, backendAud) {
		return nil, errors.New("BFF_BACKEND_AUDIENCE must appear in BFF_AUDIENCE_LIST")
	}
	workloadID := os.Getenv("BFF_WORKLOAD_ID")
	if workloadID == "" {
		// SPIRE-CSI-issued SVID would be more robust; the env-var path is
		// the local-edition simplification until Phase 7c plumbs SVIDs
		// directly into the BFF process.
		workloadID = "spiffe://secforge.local/ns/app/sa/" + c.OpenBaoRole
	}

	tokenEndpoint := strings.TrimRight(c.KCIssuer, "/") + "/protocol/openid-connect/token"
	jwksEndpoint := strings.TrimRight(c.KCIssuer, "/") + "/protocol/openid-connect/certs"

	audit := apiauth.NewAudit(apiauth.AuditConfig{Writer: os.Stdout})

	cli := apiauth.NewClient(apiauth.ClientConfig{
		TokenEndpoint:      tokenEndpoint,
		ClientID:           c.KCClientID,
		ClientAssertionPEM: clientPriv,
		AudienceList:       audList,
		SessionStore:       newBFFSessionAdapter(sess, jkt),
		DPoPKey:            dpop.priv, // ECDSA P-256 private key, see dpop.go
		HTTPClient:         http.DefaultClient,
	})

	// Middleware is constructed for completeness — see file header. ExpectedAudience
	// for any future Bearer-tier endpoint protected by this BFF would be the
	// BFF's own client_id (per Q1 / Q2 — every backend accepts only its own
	// audience).
	mw := apiauth.NewMiddleware(apiauth.MiddlewareConfig{
		Issuer:           c.KCIssuer,
		ExpectedAudience: c.KCClientID,
		JWKSEndpoint:     jwksEndpoint,
		ReplayCache:      &noopReplayCache{}, // not used in BFF; placeholder
		HTTPClient:       http.DefaultClient,
		Audit:            audit,
		WorkloadID:       workloadID,
	})

	return &apiAuthBundle{
		mw:              mw,
		cli:             cli,
		audit:           audit,
		workloadID:      workloadID,
		backendAudience: backendAud,
	}, nil
}

// noopReplayCache satisfies apiauth.ReplayCache without persisting anything.
// Used only for the placeholder Middleware construction in the BFF; future
// Bearer-tier endpoints would wire the existing Valkey instance via a
// real adapter.
type noopReplayCache struct{}

func (noopReplayCache) SeenWithin(ctx context.Context, jti string, window time.Duration) (bool, error) {
	return false, nil
}

// errToHTTP maps apiauth's typed errors to the BFF's canonical (status,
// slug) pair so proxyToBackend can write the response uniformly. This
// duplicates apiauth's internal mapping intentionally — the library
// returns errors and the consumer chooses HTTP semantics, per ADR-0014's
// "library does not write responses" rule.
func errToHTTP(err error) (int, string) {
	switch {
	case errors.Is(err, apiauth.ErrAudienceNotConfigured):
		// Configuration drift — BFF_AUDIENCE_LIST is wrong. Loud server
		// error so operators notice, not a 401 to the user.
		return 500, "audience_not_configured"
	case errors.Is(err, apiauth.ErrAudienceUnavailable):
		// Q3 fallback path — refresh-with-expanded-scope was rejected.
		// Caller clears the session cookie + redirects to /login.
		return 401, "audience_unavailable"
	case errors.Is(err, apiauth.ErrKeycloakUnreachable):
		return 502, "keycloak_unreachable"
	case errors.Is(err, apiauth.ErrInvalidToken):
		return 401, "no_session"
	default:
		return 500, "internal_error"
	}
}

// splitCommaCSV splits a comma-separated string, trimming whitespace and
// dropping empty entries.
func splitCommaCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := parts[:0]
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func sliceContains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

// base64URLDecode tolerates missing padding (JWT segments are unpadded).
func base64URLDecode(s string) ([]byte, error) {
	// JWT spec uses URL-safe base64 without padding. RawURLEncoding handles
	// the unpadded form natively.
	return base64.RawURLEncoding.DecodeString(s)
}
