// Package oidc abstracts the OIDC IdP behind a vendor-neutral interface.
// Apps depend on the Provider interface; concrete adapters (Keycloak today,
// Cognito / Okta / etc. later) live alongside it.
//
// Per Fix-after-07 §A.2 (audit findings F-APP-1 + F-APP-2), the BFF stops
// reaching into Keycloak-specific quirks (DER-SHA256 kid derivation;
// claim names like preferred_username, session_state) and instead consumes
// these via this interface. Compliance-cutover migrations land a second
// adapter rather than rewriting the BFF.
package oidc

import "context"

// Claims is the vendor-neutral subset of OIDC ID-token claims the platform
// cares about. Issuer-specific extras live in Raw.
type Claims struct {
	// Subject is the OIDC `sub` claim — the stable user identifier across
	// sessions for this IdP. Apps treat it as opaque.
	Subject string

	// PreferredUsername is the OIDC `preferred_username` claim. Optional.
	// Some IdPs (Cognito) don't populate it by default.
	PreferredUsername string

	// Email is the OIDC `email` claim. Optional. Apps that require it must
	// validate it explicitly per their threat model.
	Email string

	// SessionState is Keycloak's `session_state` claim. Empty for IdPs that
	// don't emit one; treat as opaque if non-empty.
	SessionState string

	// Roles is the flattened list of roles the platform recognizes.
	// Adapters extract from issuer-specific claim shapes (Keycloak's
	// realm_access.roles, Cognito's cognito:groups, etc.).
	Roles []string

	// Nonce is the OIDC `nonce` claim. Standard across issuers; the BFF
	// uses it for OIDC-flow replay prevention. Not Keycloak-specific —
	// included on the vendor-neutral side rather than under Raw to keep
	// the typical callback path cleanly typed.
	Nonce string

	// Raw is the full claim set as decoded from the ID token, including
	// fields not modeled above. Escape hatch for issuer-specific claims
	// the platform needs but the canonical Claims struct doesn't surface.
	// Apps using Raw should comment why and consider proposing the field
	// for promotion to a typed Claims member.
	Raw map[string]any
}

// Provider is the abstract OIDC IdP. Implementations are constructed via
// adapter-specific factory functions (e.g. NewKeycloakProvider). Apps hold
// a reference to the interface, never to a concrete type.
type Provider interface {
	// ParseIDToken validates and returns claims from a raw id_token string.
	// Validation includes signature, issuer, audience, exp/nbf, and (where
	// the IdP supports it) replay protection via JTI/nonce.
	//
	// Implementations MUST NOT log the raw ID token or any claim values
	// beyond log-safe fields (issuer URL is fine; sub/email/etc. are not).
	// Errors must include enough context for operator triage but never the
	// token itself.
	ParseIDToken(ctx context.Context, rawIDToken string) (*Claims, error)

	// KidFor returns the issuer-expected `kid` value for a given DER-PKIX
	// public key. Different IdPs derive `kid` differently (Keycloak's
	// `jwt.credential.public.key` clients use base64url(SHA-256(DER));
	// strictly RFC 7638 issuers use a JWK-thumbprint). The BFF asks the
	// adapter for the right kid when constructing client_assertion JWS
	// for private_key_jwt auth.
	KidFor(pubKeyDER []byte) string
}
