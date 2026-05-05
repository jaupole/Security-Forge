package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	libAPIAuth "github.com/secforge/lib/api-auth"
	libAuthZN "github.com/secforge/lib/authzn"
)

type server struct {
	log    *slog.Logger
	authzn libAuthZN.AuthZN
	db     *db
	mw     *libAPIAuth.Middleware
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) readyz(jwksURL string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()

		// SpiceDB health.
		if err := s.authzn.Health(ctx); err != nil {
			s.writeError(w, http.StatusServiceUnavailable, "spicedb_unhealthy", err)
			return
		}
		// DB ping (via a trivial scan; cred-refresh-on-28P01 applies).
		var one int
		if err := s.db.scanWithRetry(ctx, "SELECT 1", nil, &one); err != nil {
			s.writeError(w, http.StatusServiceUnavailable, "db_unhealthy", err)
			return
		}
		// JWKS reachable (lightweight HEAD).
		req, _ := http.NewRequestWithContext(ctx, http.MethodHead, jwksURL, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			s.writeError(w, http.StatusServiceUnavailable, "jwks_unreachable", err)
			return
		}
		_ = resp.Body.Close()
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	}
}

// getMe returns the validated user's identity. Middleware has already
// checked JWT + DPoP; we just read claims off the context.
func (s *server) getMe(w http.ResponseWriter, r *http.Request) {
	cl := libAPIAuth.ClaimsFromContext(r.Context())
	if cl == nil {
		s.writeError(w, http.StatusUnauthorized, "no_claims", errors.New("middleware did not attach claims"))
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{
		"sub":         cl.Sub,
		"realm_roles": cl.RealmRoles,
	})
}

// documentRouter dispatches /api/document/{id} between GET and POST.
// Path parsing is intentional and minimal — net/http's PathValue would
// require a Go 1.22+ pattern, which the BFF and authzen-facade aren't
// using yet. Stay consistent with the rest of the codebase's plain mux.
func (s *server) documentRouter(w http.ResponseWriter, r *http.Request) {
	docID := strings.TrimPrefix(r.URL.Path, "/api/document/")
	docID = strings.TrimSuffix(docID, "/")
	if docID == "" || strings.Contains(docID, "/") {
		s.writeError(w, http.StatusNotFound, "not_found", errors.New("malformed document id"))
		return
	}
	cl := libAPIAuth.ClaimsFromContext(r.Context())
	if cl == nil {
		s.writeError(w, http.StatusUnauthorized, "no_claims", errors.New("middleware did not attach claims"))
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.getDocument(w, r, cl, docID)
	case http.MethodPost:
		s.editDocument(w, r, cl, docID)
	default:
		w.Header().Set("Allow", "GET, POST")
		s.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", nil)
	}
}

func (s *server) getDocument(w http.ResponseWriter, r *http.Request, cl *libAPIAuth.Claims, docID string) {
	ctx := r.Context()
	subj := libAuthZN.Subject{Type: "user", ID: keycloakSubToSpicedbUserID(cl.Sub)}
	res := libAuthZN.Resource{Type: "document", ID: docID}

	dec, err := s.authzn.Evaluate(ctx, subj, "view", res)
	if err != nil {
		s.log.Error("authzn evaluate failed", "doc", docID, "err", err)
		s.writeError(w, http.StatusInternalServerError, "authzn_error", err)
		return
	}
	if !dec.Allowed {
		s.writeError(w, http.StatusForbidden, "forbidden", nil)
		return
	}

	var (
		owner     string
		content   string
		updatedAt time.Time
	)
	err = s.db.scanWithRetry(ctx,
		"SELECT owner, content, updated_at FROM helloworld.documents WHERE id=$1",
		[]any{docID},
		&owner, &content, &updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		s.writeError(w, http.StatusNotFound, "not_found", nil)
		return
	}
	if err != nil {
		s.log.Error("db read failed", "doc", docID, "err", err)
		s.writeError(w, http.StatusInternalServerError, "db_error", err)
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]any{
		"id":         docID,
		"owner":      owner,
		"content":    content,
		"updated_at": updatedAt.Format(time.RFC3339),
	})
}

func (s *server) editDocument(w http.ResponseWriter, r *http.Request, cl *libAPIAuth.Claims, docID string) {
	ctx := r.Context()
	subj := libAuthZN.Subject{Type: "user", ID: keycloakSubToSpicedbUserID(cl.Sub)}
	res := libAuthZN.Resource{Type: "document", ID: docID}

	dec, err := s.authzn.Evaluate(ctx, subj, "edit", res)
	if err != nil {
		s.log.Error("authzn evaluate failed", "doc", docID, "err", err)
		s.writeError(w, http.StatusInternalServerError, "authzn_error", err)
		return
	}
	if !dec.Allowed {
		s.writeError(w, http.StatusForbidden, "forbidden", nil)
		return
	}

	var body struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&body); err != nil {
		s.writeError(w, http.StatusBadRequest, "bad_request", err)
		return
	}
	if body.Content == "" {
		s.writeError(w, http.StatusBadRequest, "empty_content", nil)
		return
	}

	rows, err := s.db.execWithRetry(ctx,
		"UPDATE helloworld.documents SET content=$1, updated_at=now() WHERE id=$2",
		body.Content, docID,
	)
	if err != nil {
		s.log.Error("db update failed", "doc", docID, "err", err)
		s.writeError(w, http.StatusInternalServerError, "db_error", err)
		return
	}
	if rows == 0 {
		s.writeError(w, http.StatusNotFound, "not_found", nil)
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]any{
		"id":      docID,
		"updated": true,
	})
}

// keycloakSubToSpicedbUserID returns the SpiceDB user-id for a given
// Keycloak `sub` claim. The Phase 4 seed uses username-keyed tuples
// (`user:jason`, `user:alice`, `user:bob`). Phase 9.7 deploy adds
// UUID-keyed companion tuples that mirror the same access matrix, so
// the backend can pass `sub` directly without a lookup. Phase 9.12
// teardown removes the UUID-keyed forms only.
func keycloakSubToSpicedbUserID(sub string) string {
	return sub
}

func (s *server) writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// writeError writes a friendly JSON error. The internal `err` is logged
// but never echoed to the client (don't leak SQL errors / SpiceDB internals).
func (s *server) writeError(w http.ResponseWriter, status int, code string, err error) {
	if err != nil {
		s.log.Info("returning error", "status", status, "code", code, "err", err)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "message": friendlyMessage(code)})
}

func friendlyMessage(code string) string {
	switch code {
	case "forbidden":
		return "You don't have access to this resource."
	case "not_found":
		return "The requested document was not found."
	case "bad_request", "empty_content":
		return "The request was invalid."
	case "method_not_allowed":
		return "Method not allowed."
	case "no_claims":
		return "Authentication required."
	default:
		return "An internal error occurred."
	}
}

// Compile-time guard: ensure the JSON encoder import is used even if a
// future refactor drops some methods.
var _ = fmt.Sprintf
