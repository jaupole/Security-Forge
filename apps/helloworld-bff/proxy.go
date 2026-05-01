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
		idTok, err := o.verifier.Verify(r.Context(), tr.IDToken)
		if err != nil {
			slog.Error("id_token verify failed", "err", err)
			httpJSON(w, 502, errBody("id_token_invalid"))
			return
		}
		var claims struct {
			Sub               string `json:"sub"`
			PreferredUsername string `json:"preferred_username"`
			Nonce             string `json:"nonce"`
			SessionState      string `json:"session_state"`
		}
		if err := idTok.Claims(&claims); err != nil {
			httpJSON(w, 502, errBody("id_token_claims"))
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
			Sub:            claims.Sub,
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
func proxyToBackend(c cfg, o *oidcClient, s *sessionStore, dpop *dpopSigner) http.HandlerFunc {
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
	return func(w http.ResponseWriter, r *http.Request) {
		// Inbound DPoP requires forwarded headers. Fail-closed.
		if _, err := inboundHTU(r); err != nil {
			httpJSON(w, 400, errBody("missing_forwarded_headers"))
			return
		}
		sid := readSessionCookie(r)
		if sid == "" {
			httpJSON(w, 401, errBody("no_session"))
			return
		}
		sv, err := s.get(r.Context(), sid)
		if err != nil {
			httpJSON(w, 401, errBody("session_invalid"))
			return
		}
		// Refresh if needed (single-flight).
		now := time.Now().Unix()
		if sv.AccessExp-now < 30 || sv.DPoPJktAtIssue != dpop.jkt {
			refreshed, rerr := s.withRefreshLock(r.Context(), sid, func() (sessionV1, error) {
				tr, terr := o.refresh(r.Context(), dpop, sv.RefreshToken)
				if terr != nil {
					return sv, terr
				}
				sv.AccessToken = tr.AccessToken
				if tr.RefreshToken != "" {
					sv.RefreshToken = tr.RefreshToken
				}
				sv.AccessExp = time.Now().Unix() + int64(tr.ExpiresIn)
				sv.RefreshExp = time.Now().Unix() + int64(tr.RefreshExpiresIn)
				sv.DPoPJktAtIssue = dpop.jkt
				return sv, s.put(r.Context(), sid, sv)
			})
			if rerr != nil {
				slog.Error("token refresh failed", "err", rerr, "sid_prefix", sid[:8])
				httpJSON(w, 502, errBody("refresh_failed"))
				return
			}
			sv = refreshed
		} else {
			_ = s.touch(r.Context(), sid, sv)
		}
		// Mint per-call DPoP proof for the upstream URL.
		upstreamURL := target.String() + r.URL.Path
		if r.URL.RawQuery != "" {
			upstreamURL += "?" + r.URL.RawQuery
		}
		proof, err := dpop.proofFor(r.Method, upstreamURL, sv.AccessToken)
		if err != nil {
			httpJSON(w, 500, errBody("dpop_proof"))
			return
		}
		r.Header.Set("Authorization", "DPoP "+sv.AccessToken)
		r.Header.Set("DPoP", proof)
		r.Header.Set("X-User-Sub", sv.Sub)
		r.Header.Set("X-Request-Id", uuidOrEmpty(r.Header.Get("X-Request-Id")))
		rp.ServeHTTP(w, r)
	}
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
