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
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	authzed "github.com/authzed/authzed-go/v1"
	"github.com/authzed/grpcutil"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
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

// server holds the SpiceDB client and the structured logger.
type server struct {
	client *authzed.Client
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

	tlsCfg, err := tlsConfigFromCA(caFile)
	if err != nil {
		logger.Error("failed to build TLS config", "ca", caFile, "err", err)
		os.Exit(1)
	}

	client, err := authzed.NewClient(
		endpoint,
		grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)),
		grpcutil.WithBearerToken(token),
	)
	if err != nil {
		logger.Error("failed to dial SpiceDB", "endpoint", endpoint, "err", err)
		os.Exit(1)
	}

	srv := &server{client: client, logger: logger}

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

// readyz performs a SpiceDB ReadSchema as a smoke test that the
// downstream is reachable. Cheap (sub-ms cached) and a real
// integration probe rather than just "the process is up".
func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if _, err := s.client.ReadSchema(ctx, &v1.ReadSchemaRequest{}); err != nil {
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

	resp, err := s.client.CheckPermission(ctx, &v1.CheckPermissionRequest{
		Resource: &v1.ObjectReference{
			ObjectType: req.Resource.Type,
			ObjectId:   req.Resource.ID,
		},
		Permission: req.Action.Name,
		Subject: &v1.SubjectReference{
			Object: &v1.ObjectReference{
				ObjectType: req.Subject.Type,
				ObjectId:   req.Subject.ID,
			},
		},
		Consistency: &v1.Consistency{
			// minimize_latency is correct for the steady-state fast path.
			// Read-your-writes flows pass an explicit ZedToken via the
			// context object (not yet wired — Caveats and ZedToken
			// chaining come with the first app that needs them).
			Requirement: &v1.Consistency_MinimizeLatency{MinimizeLatency: true},
		},
	})

	// Audit log every CheckPermission decision. This is the durable
	// record consumed by Phase 7 Loki/Wazuh; lower verbosity drops it.
	s.logger.Info("evaluate",
		"subject", req.Subject.Type+":"+req.Subject.ID,
		"resource", req.Resource.Type+":"+req.Resource.ID,
		"action", req.Action.Name,
		"err", err,
		"decision", resp.GetPermissionship() == v1.CheckPermissionResponse_PERMISSIONSHIP_HAS_PERMISSION,
	)

	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, evaluationResponse{
		Decision: resp.Permissionship == v1.CheckPermissionResponse_PERMISSIONSHIP_HAS_PERMISSION,
	})
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

// tlsConfigFromCA builds a TLS client config that trusts the supplied
// CA bundle. We do NOT skip verification; the cert mounted into the
// SpiceDB pod was issued by the mkcert ClusterIssuer for the in-cluster
// service name, and we mount the same CA here.
func tlsConfigFromCA(caFile string) (*tls.Config, error) {
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read ca: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("ca pem contained no certs")
	}
	return &tls.Config{
		RootCAs:    pool,
		MinVersion: tls.VersionTLS13,
	}, nil
}
