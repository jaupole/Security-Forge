package main

// HTTP handlers + reverse proxy. Implements:
//   - login flow (PAR + redirect to Keycloak)
//   - callback (code exchange, session persistence, cookie issuance)
//   - logout (local invalidate FIRST, then best-effort revoke, then KC end-session)
//   - /api/* upstream with Bearer + DPoP injection
//   - /* upstream to frontend (or 502 if no frontend configured yet)

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
	apiauth "github.com/secforge/lib/api-auth"
)

const cookieName = "__Host-bff_sid"

// Login: build state + PKCE, push to PAR, redirect to authorization_endpoint.
func handleLogin(c cfg, o *oidcClient, s *sessionStore, dpop *dpopSigner) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		state, err := newOpaqueID()
		if err != nil {
			httpJSON(w, 500, errBody("state"))
			return
		}
		nonce, err := newOpaqueID()
		if err != nil {
			httpJSON(w, 500, errBody("nonce"))
			return
		}
		verifier, challenge, err := pkceVerifier()
		if err != nil {
			httpJSON(w, 500, errBody("pkce"))
			return
		}
		next := r.URL.Query().Get("next")
		if next == "" || !strings.HasPrefix(next, "/") {
			next = "/"
		}
		if err := s.putLogin(r.Context(), state, loginV1{PKCEVerifier: verifier, Nonce: nonce, RedirectAfterLogin: next}); err != nil {
			httpJSON(w, 502, errBody("valkey"))
			return
		}
		redirectURI := c.PublicOrigin + "/auth/callback"
		reqURI, err := o.par(r.Context(), dpop, redirectURI, state, nonce, challenge)
		if err != nil {
			slog.Error("PAR failed", "err", err)
			httpJSON(w, 502, errBody("par"))
			return
		}
		authURL := o.endpoints.AuthorizationEndpoint + "?client_id=" + url.QueryEscape(c.KCClientID) + "&request_uri=" + url.QueryEscape(reqURI)
		http.Redirect(w, r, authURL, http.StatusFound)
	}
}

// Callback: validate state, redeem code, persist session, set cookie, redirect.
func handleCallback(c cfg, o *oidcClient, s *sessionStore, dpop *dpopSigner) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		state := r.URL.Query().Get("state")
		code := r.URL.Query().Get("code")
		if state == "" || code == "" {
			httpJSON(w, 400, errBody("missing_state_or_code"))
			return
		}
		login, err := s.takeLogin(r.Context(), state)
		if err != nil {
			httpJSON(w, 400, errBody("invalid_state"))
			return
		}
		redirectURI := c.PublicOrigin + "/auth/callback"
		tr, err := o.exchange(r.Context(), dpop, redirectURI, code, login.PKCEVerifier)
		if err != nil {
			slog.Error("code exchange failed", "err", err)
			httpJSON(w, 502, errBody("token_exchange"))
			return
		}
		// ID-token verification + claim extraction lives in the
		// vendor-neutral lib (Fix-after-07 §A.5). The BFF just gets
		// claims back and runs the OAuth-flow nonce check.
		claims, err := o.libProv.ParseIDToken(r.Context(), tr.IDToken)
		if err != nil {
			slog.Error("id_token verify failed", "err", err)
			httpJSON(w, 502, errBody("id_token_invalid"))
			return
		}
		if claims.Nonce != login.Nonce {
			httpJSON(w, 400, errBody("nonce_mismatch"))
			return
		}
		sid, err := newOpaqueID()
		if err != nil {
			httpJSON(w, 500, errBody("sid"))
			return
		}
		now := time.Now().Unix()
		sv := sessionV1{
			Sub:            claims.Subject,
			PreferredUser:  claims.PreferredUsername,
			SessionState:   claims.SessionState,
			AccessToken:    tr.AccessToken,
			RefreshToken:   tr.RefreshToken,
			IDToken:        tr.IDToken,
			AccessExp:      now + int64(tr.ExpiresIn),
			RefreshExp:     now + int64(tr.RefreshExpiresIn),
			Scope:          tr.Scope,
			DPoPJktAtIssue: dpop.jkt,
		}
		if err := s.put(r.Context(), sid, sv); err != nil {
			httpJSON(w, 502, errBody("valkey"))
			return
		}
		setSessionCookie(w, sid)
		http.Redirect(w, r, login.RedirectAfterLogin, http.StatusFound)
	}
}

// Logout: order matters. See design doc §"Logout sequence" failure matrix.
func handleLogout(c cfg, o *oidcClient, s *sessionStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// CSRF: Origin must match our public origin.
		if r.Header.Get("Origin") != c.PublicOrigin {
			httpJSON(w, 403, errBody("origin_mismatch"))
			return
		}
		sid := readSessionCookie(r)
		var idToken string
		if sid != "" {
			sv, err := s.get(r.Context(), sid)
			if err == nil {
				idToken = sv.IDToken
			}
			if delErr := s.del(r.Context(), sid); delErr != nil && !errors.Is(delErr, redis.Nil) {
				// We do NOT clear the cookie if local deletion failed —
				// the user retries when Valkey is back.
				slog.Error("session del failed", "err", delErr)
				httpJSON(w, 503, errBody("valkey"))
				return
			}
			if sv.RefreshToken != "" {
				go o.revoke(context.Background(), sv.RefreshToken)
			}
		}
		clearSessionCookie(w)
		end := o.endpoints.EndSessionEndpoint + "?post_logout_redirect_uri=" + url.QueryEscape(c.PublicOrigin+"/")
		if idToken != "" {
			end += "&id_token_hint=" + url.QueryEscape(idToken)
		}
		http.Redirect(w, r, end, http.StatusFound)
	}
}

// proxyToBackend reverse-proxies /api/* to the backend with Bearer + DPoP.
//
// Phase 6b-1: token acquisition + audience-at-login refresh now flow
// through apiauth.Client.MintTokenForAudience (apps/lib/api-auth/client.go).
// The DPoP proof for the upstream URL is still minted by the BFF's
// per-pod dpopSigner (separate from the api-auth library's role).
//
// Three Audit.LogHop sites per Phase 6b-1 § Section 6:
//
//	(a) inbound edge — at the entry of the protected handler, hop_index=1
//	(b) outbound attempt — before the upstream HTTP call, hop_index=2,
//	    status=0 (pre-call sentinel)
//	(c) outbound result — after the upstream response, hop_index=2 with
//	    the actual status code
func proxyToBackend(c cfg, o *oidcClient, s *sessionStore, dpop *dpopSigner, ap *apiAuthBundle) http.HandlerFunc {
	if c.BackendURL == "" {
		return func(w http.ResponseWriter, _ *http.Request) {
			httpJSON(w, 502, errBody("no_backend_configured"))
		}
	}
	target, err := url.Parse(c.BackendURL)
	if err != nil {
		slog.Error("invalid backend URL", "err", err)
		return func(w http.ResponseWriter, _ *http.Request) {
			httpJSON(w, 500, errBody("backend_url_parse"))
		}
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	origDirector := rp.Director
	rp.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
	}
	// ModifyResponse fires after the upstream returns; we use it to emit
	// the third LogHop with the actual status. The closure captures ap
	// + the per-request user_sub/request_id via the request context (we
	// stash them via withReqMeta below).
	rp.ModifyResponse = func(resp *http.Response) error {
		meta := metaFromCtx(resp.Request.Context())
		_ = ap.audit.LogHop(resp.Request, 2, ap.workloadID, meta.userSub, ap.backendAudience, resp.StatusCode)
		return nil
	}
	return func(w http.ResponseWriter, r *http.Request) {
		// Inbound DPoP requires forwarded headers. Fail-closed.
		if _, err := inboundHTU(r); err != nil {
			httpJSON(w, 400, errBody("missing_forwarded_headers"))
			return
		}
		sid := readSessionCookie(r)
		if sid == "" {
			// Audit denial at hop_index=1 with status=401.
			_ = ap.audit.LogHop(r, 1, ap.workloadID, "", ap.backendAudience, 401)
			httpJSON(w, 401, errBody("no_session"))
			return
		}
		// Look up session for the user_sub used in audit lines.
		sv, err := s.get(r.Context(), sid)
		if err != nil {
			_ = ap.audit.LogHop(r, 1, ap.workloadID, "", ap.backendAudience, 401)
			httpJSON(w, 401, errBody("session_invalid"))
			return
		}

		// (a) Inbound LogHop — request accepted at the BFF edge.
		_ = ap.audit.LogHop(r, 1, ap.workloadID, sv.Sub, ap.backendAudience, 200)

		// Replace prior cached-or-refresh dance with apiauth.Client. The
		// Client handles the cache-hit short-circuit, the audience-at-login
		// refresh, and the defense-in-depth aud check on the new token.
		ctx := apiauth.ContextWithSessionKey(r.Context(), sid)
		accessToken, mintErr := ap.cli.MintTokenForAudience(ctx, ap.backendAudience)
		if mintErr != nil {
			status, slug := errToHTTP(mintErr)
			if errors.Is(mintErr, apiauth.ErrAudienceUnavailable) {
				// Q3 fallback path — clear session and redirect to /login.
				clearSessionCookie(w)
				w.Header().Set("Location", "/login")
			}
			_ = ap.audit.LogHop(r, 2, ap.workloadID, sv.Sub, ap.backendAudience, status)
			httpJSON(w, status, errBody(slug))
			return
		}

		// Mint per-call DPoP proof for the upstream URL — the BFF's job,
		// not the api-auth library's.
		upstreamURL := target.String() + r.URL.Path
		if r.URL.RawQuery != "" {
			upstreamURL += "?" + r.URL.RawQuery
		}
		proof, err := dpop.proofFor(r.Method, upstreamURL, accessToken)
		if err != nil {
			_ = ap.audit.LogHop(r, 2, ap.workloadID, sv.Sub, ap.backendAudience, 500)
			httpJSON(w, 500, errBody("dpop_proof"))
			return
		}
		r.Header.Set("Authorization", "DPoP "+accessToken)
		r.Header.Set("DPoP", proof)
		r.Header.Set("X-User-Sub", sv.Sub)
		r.Header.Set("X-Request-Id", uuidOrEmpty(r.Header.Get("X-Request-Id")))

		// (b) Outbound attempt LogHop — emitted before the upstream call;
		// status=0 marks "in flight." The (c) outbound-result LogHop fires
		// from rp.ModifyResponse with the actual status.
		_ = ap.audit.LogHop(r, 2, ap.workloadID, sv.Sub, ap.backendAudience, 0)

		// Stash user_sub on the context so ModifyResponse's LogHop can
		// pick it up without re-reading the session.
		r = r.WithContext(withReqMeta(r.Context(), reqMeta{userSub: sv.Sub}))

		// Touch session so idle TTL extends.
		_ = s.touch(r.Context(), sid, sv)

		rp.ServeHTTP(w, r)
	}
}

// reqMeta carries per-request state ModifyResponse needs after the
// upstream call.
type reqMeta struct {
	userSub string
}

type reqMetaKey struct{}

func withReqMeta(ctx context.Context, m reqMeta) context.Context {
	return context.WithValue(ctx, reqMetaKey{}, m)
}

func metaFromCtx(ctx context.Context) reqMeta {
	v, _ := ctx.Value(reqMetaKey{}).(reqMeta)
	return v
}

// proxyToFrontend reverse-proxies /* to the frontend pod, propagating
// the per-request CSP nonce via X-CSP-Nonce request header.
func proxyToFrontend(c cfg, _ *sessionStore) http.HandlerFunc {
	if c.FrontendURL == "" {
		return func(w http.ResponseWriter, _ *http.Request) {
			httpJSON(w, 502, errBody("no_frontend_configured"))
		}
	}
	target, err := url.Parse(c.FrontendURL)
	if err != nil {
		return func(w http.ResponseWriter, _ *http.Request) {
			httpJSON(w, 500, errBody("frontend_url_parse"))
		}
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	origDirector := rp.Director
	rp.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
	}
	return func(w http.ResponseWriter, r *http.Request) {
		// Forward per-request CSP nonce so the frontend can inline it.
		if n := nonceFromCtx(r.Context()); n != "" {
			r.Header.Set("X-CSP-Nonce", n)
		}
		rp.ServeHTTP(w, r)
	}
}

// Cookie helpers.

func setSessionCookie(w http.ResponseWriter, sid string) {
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    sid,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
}

func readSessionCookie(r *http.Request) string {
	c, err := r.Cookie(cookieName)
	if err != nil {
		return ""
	}
	return c.Value
}

// Tiny JSON helpers.

func httpJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func errBody(slug string) map[string]string { return map[string]string{"error": slug} }

func uuidOrEmpty(s string) string {
	if s != "" {
		return s
	}
	return uuid.NewString()
}
