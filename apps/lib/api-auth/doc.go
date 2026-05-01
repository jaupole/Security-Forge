// Package apiauth implements the SecForge audience-at-login API auth pattern
// per ADR-0014: docs/02-decisions/0014-api-auth-library-design.md.
//
// Three primary types — Middleware, Client, Audit — wrap the inbound JWT+DPoP
// validation, outbound downstream-API token minting, and per-hop structured
// audit logging that every SecForge BFF and backend API uses. The library is
// vendor-neutral over its inputs (caller-supplied issuer URL, JWKS endpoint,
// session store, replay cache, DPoP key, audit sink) and never loads its own
// secrets — see ADR-0013 and ADR-0019 for the secret distribution split.
//
// The library does NOT implement RFC 8693 token-exchange (NO-GO per ADR-0012);
// outbound tokens are minted via Keycloak refresh with expanded scope. See
// ADR-0014 § Out-of-scope for the full list of intentionally-omitted features.
package apiauth
