package main

// Security headers + per-request CSP nonce. See design doc §"CSP nonce
// plumbing" — nonce never reused; same value used in CSP response header
// and in X-CSP-Nonce request header for the frontend hop.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/url"
)

type ctxKey struct{}

var nonceCtxKey = ctxKey{}

func nonceFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(nonceCtxKey).(string)
	return v
}

func newNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func withSecurityHeaders(c cfg, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nonce := newNonce()
		ctx := context.WithValue(r.Context(), nonceCtxKey, nonce)

		h := w.Header()
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload")
		h.Set("X-Frame-Options", "DENY")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Content-Security-Policy",
			"default-src 'none'; "+
				"script-src 'self' 'nonce-"+nonce+"' 'strict-dynamic'; "+
				"style-src 'self' 'nonce-"+nonce+"'; "+
				"img-src 'self' data:; "+
				"font-src 'self'; "+
				"connect-src 'self'; "+
				"frame-ancestors 'none'; "+
				"base-uri 'none'; "+
				"form-action 'self' "+formActionAllow(c)+"; "+
				"require-trusted-types-for 'script'; "+
				"upgrade-insecure-requests")

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func formActionAllow(c cfg) string {
	// Allow Keycloak's origin so the OIDC redirect form-post (if used)
	// passes CSP. Returns scheme://host[:port] of the issuer URL.
	if c.KCIssuer == "" {
		return ""
	}
	u, err := url.Parse(c.KCIssuer)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return ""
	}
	return u.Scheme + "://" + u.Host
}
