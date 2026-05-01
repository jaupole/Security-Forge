// AuthZEN façade — translates OpenID AuthZEN 1.0 evaluation requests
// to SpiceDB CheckPermission RPCs.
//
// Spec:        https://openid.net/specs/authorization-api-1_0.html
// Architecture: docs/01-architecture/02-authorization.md
// SpiceDB:     in-cluster gRPC at spicedb.spicedb.svc.cluster.local:50051
//
// Endpoints
//   GET  /healthz             liveness
//   GET  /readyz              readiness (includes a CheckPermission round-trip)
//   POST /access/v1/evaluation  AuthZEN 1.0 evaluation
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	libAuthZN "github.com/secforge/lib/authzn"
)

// AuthZEN 1.0 request and response types. We implement only what's
// needed to translate to a single SpiceDB CheckPermission call.

type subject struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type action struct {
	Name string `json:"name"`
}

type resource struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type evaluationRequest struct {
	Subject  subject  `json:"subject"`
	Action   action   `json:"action"`
	Resource resource `json:"resource"`

	// Optional context — passed through but unused today (no Caveats in
	// the schema yet). When Caveats are added, this is where the
	// per-request context lands.
	Context map[string]any `json:"context,omitempty"`
}

type evaluationResponse struct {
	Decision bool `json:"decision"`
}

type errorResponse struct {
	Error string `json:"error"`
}

// server holds the authorization engine + structured logger. The
// engine is consumed via the vendor-neutral AuthZN interface from
// apps/lib/authzn; concrete adapter selection happens at construction
// (Fix-after-07 §A.6).
type server struct {
	authzn libAuthZN.AuthZN
	logger *slog.Logger
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	tracerCtx, tracerCancel := context.WithCancel(context.Background())
	defer tracerCancel()
	shutdownTracer, err := initTracer(tracerCtx)
	if err != nil {
		logger.Error("tracer init failed", "err", err)
		os.Exit(1)
	}
	defer func() {
		fctx, fcancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer fcancel()
		_ = shutdownTracer(fctx)
	}()

	endpoint := envOr("SPICEDB_ENDPOINT", "spicedb.spicedb.svc.cluster.local:50051")
	tokenFile := envOr("SPICEDB_TOKEN_FILE", "/etc/spicedb/preshared_key")
	caFile := envOr("SPICEDB_CA_FILE", "/etc/spicedb/ca.crt")
	listenAddr := envOr("LISTEN_ADDR", ":8080")

	tokenBytes, err := os.ReadFile(tokenFile)
	if err != nil {
		logger.Error("failed to read SpiceDB pre-shared key", "path", tokenFile, "err", err)
		os.Exit(1)
	}
	token := strings.TrimSpace(string(tokenBytes))

	// Construct the authorization engine via the vendor-neutral lib.
	// SpiceDB-specific dial + TLS + bearer-token plumbing lives in
	// apps/lib/authzn/spicedb.go.
	authzn, err := libAuthZN.NewSpiceDBAuthZN(endpoint, token, caFile)
	if err != nil {
		logger.Error("failed to construct authzn engine", "endpoint", endpoint, "err", err)
		os.Exit(1)
	}

	srv := &server{authzn: authzn, logger: logger}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.healthz)
	mux.HandleFunc("/readyz", srv.readyz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/access/v1/evaluation", srv.evaluation)

	tracedHandler := otelhttp.NewHandler(
		mux,
		"authzen-facade",
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/metrics" && r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
		}),
	)

	httpSrv := &http.Server{
		Addr:              listenAddr,
		Handler:           tracedHandler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	logger.Info("authzen-facade listening", "addr", listenAddr, "spicedb", endpoint)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server failed", "err", err)
		os.Exit(1)
	}
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// readyz exercises the authzn engine via a vendor-neutral Health probe.
// SpiceDB adapter implements this with ReadSchema; other adapters use
// whatever cheap call proves connectivity + auth + policy load.
func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.authzn.Health(ctx); err != nil {
		s.logger.Warn("readyz failed", "err", err)
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *server) evaluation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "use POST")
		return
	}

	var req evaluationRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("decode: %v", err))
		return
	}

	if !validIDPart(req.Subject.Type) || !validIDPart(req.Subject.ID) ||
		!validIDPart(req.Resource.Type) || !validIDPart(req.Resource.ID) ||
		!validIDPart(req.Action.Name) {
		writeError(w, http.StatusBadRequest,
			"subject/resource type and id and action.name must be non-empty and contain only [A-Za-z0-9_/-]")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	decision, err := s.authzn.Evaluate(ctx,
		libAuthZN.Subject{Type: req.Subject.Type, ID: req.Subject.ID},
		req.Action.Name,
		libAuthZN.Resource{Type: req.Resource.Type, ID: req.Resource.ID},
	)

	// Audit log every evaluation. This is the durable record consumed
	// by Phase 7 Loki/Wazuh; lower verbosity drops it.
	allowed := false
	if decision != nil {
		allowed = decision.Allowed
	}
	s.logger.Info("evaluate",
		"subject", req.Subject.Type+":"+req.Subject.ID,
		"resource", req.Resource.Type+":"+req.Resource.ID,
		"action", req.Action.Name,
		"err", err,
		"decision", allowed,
	)

	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, evaluationResponse{Decision: allowed})
}

// validIDPart enforces a conservative allow-list — letters, digits,
// underscore, hyphen, slash. Stops a request from injecting whitespace
// or `@`/`#` that would alter SpiceDB's relationship grammar.
func validIDPart(s string) bool {
	if s == "" || len(s) > 256 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '_', r == '-', r == '/':
		default:
			return false
		}
	}
	return true
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, errorResponse{Error: msg})
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// tlsConfigFromCA used to build the gRPC TLS config locally. After
// Fix-after-07 §A.6, dialing SpiceDB lives behind apps/lib/authzn —
// which reads the CA path itself. The function below is gone; the
// CA file path passes through to the lib via NewSpiceDBAuthZN.
