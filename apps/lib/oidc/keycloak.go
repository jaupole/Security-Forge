package oidc

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"

	gooidc "github.com/coreos/go-oidc/v3/oidc"
)

// KeycloakProvider is the Keycloak adapter for Provider.
//
// It speaks Keycloak's specific quirks behind the vendor-neutral interface:
//   - KidFor uses base64url(SHA-256(DER-PKIX-encoded public key)), Keycloak's
//     idiosyncratic kid derivation for `jwt.credential.public.key` clients
//     (NOT the RFC 7638 JWK thumbprint that other IdPs use).
//   - ParseIDToken extracts the standard subset plus Keycloak's
//     session_state and realm_access.roles, mapped onto Claims.
//
// Construct via NewKeycloakProvider. The struct is unexported intentionally —
// callers hold the Provider interface, not the concrete type.
type KeycloakProvider struct {
	issuer   string
	audience string
	verifier *gooidc.IDTokenVerifier
}

// NewKeycloakProvider does OIDC discovery against issuerURL and builds an
// IDTokenVerifier configured for the given audience (Keycloak `client_id`).
// The httpClient must trust the issuer's TLS chain — the BFF passes one
// configured with the mkcert local CA via runtime cert bundle.
//
// Discovery is one-shot at construction; the JWKS is fetched lazily by
// the verifier on first ParseIDToken call (and cached + refreshed on kid
// miss by go-oidc).
func NewKeycloakProvider(ctx context.Context, issuerURL, audience string, httpClient *http.Client) (Provider, error) {
	if issuerURL == "" {
		return nil, errors.New("issuerURL required")
	}
	if audience == "" {
		return nil, errors.New("audience required")
	}
	ctx = gooidc.ClientContext(ctx, httpClient)
	prov, err := gooidc.NewProvider(ctx, issuerURL)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery for %s: %w", issuerURL, err)
	}
	v := prov.Verifier(&gooidc.Config{ClientID: audience})
	return &KeycloakProvider{
		issuer:   issuerURL,
		audience: audience,
		verifier: v,
	}, nil
}

// KidFor returns Keycloak's `kid` for a given DER-PKIX public key:
// base64url(SHA-256(DER)). NOT RFC 7638. Empirically verified against
// Keycloak 26.x — using an RFC 7638 kid causes Keycloak to reject the
// client_assertion with "PublicKey wasn't found in the storage".
func (k *KeycloakProvider) KidFor(pubKeyDER []byte) string {
	sum := sha256.Sum256(pubKeyDER)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// ParseIDToken verifies the ID token and returns claims. Verification
// covers signature, issuer, audience, exp/nbf — all delegated to go-oidc.
//
// The returned Claims preserve the raw decoded claim map under Raw so
// callers needing Keycloak-specific fields the typed struct doesn't
// surface have an escape hatch (and a clear marker that they're using
// vendor-specific data, which makes a future provider swap auditable).
func (k *KeycloakProvider) ParseIDToken(ctx context.Context, rawIDToken string) (*Claims, error) {
	idTok, err := k.verifier.Verify(ctx, rawIDToken)
	if err != nil {
		// go-oidc returns descriptive errors; we wrap to mark the
		// boundary but deliberately do NOT include the token in the
		// error message — that would leak claim values into logs.
		return nil, fmt.Errorf("verify id_token: %w", err)
	}

	// The Keycloak-shaped fields. Roles ride under realm_access.roles.
	var k8 struct {
		Sub               string `json:"sub"`
		PreferredUsername string `json:"preferred_username"`
		Email             string `json:"email"`
		SessionState      string `json:"session_state"`
		Nonce             string `json:"nonce"`
		RealmAccess       struct {
			Roles []string `json:"roles"`
		} `json:"realm_access"`
	}
	if err := idTok.Claims(&k8); err != nil {
		return nil, fmt.Errorf("decode id_token claims: %w", err)
	}

	// Also surface the full raw claim set under Raw — without leaking
	// the raw token string anywhere.
	raw := map[string]any{}
	_ = idTok.Claims(&raw)

	return &Claims{
		Subject:           k8.Sub,
		PreferredUsername: k8.PreferredUsername,
		Email:             k8.Email,
		SessionState:      k8.SessionState,
		Nonce:             k8.Nonce,
		Roles:             append([]string{}, k8.RealmAccess.Roles...),
		Raw:               raw,
	}, nil
}
