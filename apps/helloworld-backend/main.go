// helloworld-backend — Phase 9 reference backend that exercises the
// full SecForge platform stack on every request.
//
// Wire contract: docs/01-architecture/10-helloworld-demo.md § Request flow
//
// Endpoints
//
//	GET  /api/me              return validated user info from the JWT
//	GET  /api/document/:id    SpiceDB CheckPermission "view"; on ALLOW, read from helloworld.documents
//	POST /api/document/:id    SpiceDB CheckPermission "edit"; on ALLOW, update helloworld.documents (echo for the demo)
//	GET  /healthz             liveness (always 200)
//	GET  /readyz              readiness (JWKS + SpiceDB + DB reachable)
//	GET  /metrics             Prometheus
//
// Auth chain on every /api/* call (per apps/lib/api-auth.Middleware.ValidateInbound):
//   1. JWT signature against Keycloak JWKS (cached, refresh-on-kid-miss)
//   2. iss + aud + exp/nbf/iat
//   3. DPoP htm/htu/iat/jti/cnf.jkt; htu canonicalized per docs/06-reference/dpop-htu-canonicalization.md
//   4. jti replay protection via the in-process LRU
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	libAPIAuth "github.com/secforge/lib/api-auth"
	libAuthZN "github.com/secforge/lib/authzn"
	libSecrets "github.com/secforge/lib/secrets"
)

// cfg holds every backend configuration knob, all sourced from env vars.
// No defaults that could leak across environments.
type cfg struct {
	ListenAddr        string
	PublicOrigin      string // canonical https URL (drives htu validation)
	KCIssuer          string // OIDC issuer (e.g. https://auth.secforge.local/realms/secforge-tenants)
	KCJWKSEndpoint    string // JWKS URL
	ExpectedAudience  string // this backend's audience claim (e.g. "helloworld-backend")
	WorkloadID        string // SPIFFE-SVID for audit lines

	SpiceDBEndpoint  string
	SpiceDBTokenPath string
	SpiceDBCAPath    string

	OpenBaoAddr     string
	OpenBaoRole     string // helloworld-backend
	OpenBaoSVIDPath string // path inside pod where spiffe-helper writes the JWT-SVID
	OpenBaoDBRole   string // database role suffix (e.g. "readwrite") — bao path: database/creds/helloworld-backend-readwrite

	DBHost      string
	DBPort      string
	DBName      string
	DBSSLMode   string

	ShutdownGrace time.Duration
}

func loadCfg() (cfg, error) {
	c := cfg{
		ListenAddr:    getenv("LISTEN_ADDR", ":8080"),
		ShutdownGrace: 15 * time.Second,
	}
	c.PublicOrigin = mustEnv("BACKEND_PUBLIC_ORIGIN")
	c.KCIssuer = mustEnv("BACKEND_KEYCLOAK_ISSUER")
	c.KCJWKSEndpoint = mustEnv("BACKEND_KEYCLOAK_JWKS_URL")
	c.ExpectedAudience = mustEnv("BACKEND_EXPECTED_AUDIENCE")
	c.WorkloadID = mustEnv("BACKEND_WORKLOAD_ID")

	c.SpiceDBEndpoint = getenv("SPICEDB_ENDPOINT", "spicedb.spicedb.svc.cluster.local:50051")
	c.SpiceDBTokenPath = getenv("SPICEDB_PSK_PATH", "/etc/spicedb/preshared_key")
	c.SpiceDBCAPath = getenv("SPICEDB_CA_PATH", "/etc/spicedb/ca.crt")

	c.OpenBaoAddr = mustEnv("BACKEND_OPENBAO_ADDR")
	c.OpenBaoRole = getenv("BACKEND_OPENBAO_ROLE", "helloworld-backend")
	c.OpenBaoSVIDPath = getenv("BACKEND_OPENBAO_SVID_PATH", "/shared/openbao.jwt")
	c.OpenBaoDBRole = getenv("BACKEND_OPENBAO_DB_ROLE", "readwrite")

	c.DBHost = getenv("BACKEND_DB_HOST", "secforge-app-db-rw.app.svc.cluster.local")
	c.DBPort = getenv("BACKEND_DB_PORT", "5432")
	c.DBName = getenv("BACKEND_DB_NAME", "secforge_app")
	c.DBSSLMode = getenv("BACKEND_DB_SSLMODE", "require")
	return c, nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	c, err := loadCfg()
	if err != nil {
		log.Error("config load failed", "err", err)
		os.Exit(1)
	}
	log.Info("starting", "public_origin", c.PublicOrigin, "issuer", c.KCIssuer, "workload_id", c.WorkloadID)

	tracerCtx, tracerCancel := context.WithCancel(context.Background())
	defer tracerCancel()
	shutdownTracer, err := initTracer(tracerCtx)
	if err != nil {
		log.Error("tracer init failed", "err", err)
		os.Exit(1)
	}
	defer func() {
		fctx, fcancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer fcancel()
		_ = shutdownTracer(fctx)
	}()

	// SpiceDB authorization engine.
	pskBytes, err := os.ReadFile(c.SpiceDBTokenPath)
	if err != nil {
		log.Error("read SpiceDB pre-shared key", "path", c.SpiceDBTokenPath, "err", err)
		os.Exit(1)
	}
	authzn, err := libAuthZN.NewSpiceDBAuthZN(c.SpiceDBEndpoint, strings.TrimSpace(string(pskBytes)), c.SpiceDBCAPath)
	if err != nil {
		log.Error("authzn init failed", "endpoint", c.SpiceDBEndpoint, "err", err)
		os.Exit(1)
	}

	// OpenBao bootstrapper for dynamic Postgres credentials.
	// clientKVPath is unused for the backend (no private_key_jwt) but the
	// constructor requires it — pass a sentinel that the backend never
	// reads from to make the intent explicit.
	bs, err := libSecrets.NewOpenBaoBootstrapper(c.OpenBaoAddr, c.OpenBaoSVIDPath, c.OpenBaoRole, "secret/data/apps/helloworld-backend/unused")
	if err != nil {
		log.Error("openbao bootstrapper init failed", "err", err)
		os.Exit(1)
	}
	secretsClient, err := libSecrets.New(bs, libSecrets.Config{
		AppName:  c.OpenBaoRole, // → database/creds/helloworld-backend-readwrite
		Hardened: true,
	})
	if err != nil {
		log.Error("secrets client init failed", "err", err)
		os.Exit(1)
	}

	// Postgres pool with cred-refresh-on-28P01.
	dbPool, err := newDB(context.Background(), c, secretsClient, log)
	if err != nil {
		log.Error("db pool init failed", "err", err)
		os.Exit(1)
	}
	defer dbPool.Close()

	// API auth middleware. Audit emits a structured line per inbound
	// request — accept (status=200) or reject (status=401/etc + slug).
	// Same Audit instance the BFF uses; output goes to stdout for Loki.
	apiAudit := libAPIAuth.NewAudit(libAPIAuth.AuditConfig{Writer: os.Stdout})
	mw := libAPIAuth.NewMiddleware(libAPIAuth.MiddlewareConfig{
		Issuer:           c.KCIssuer,
		ExpectedAudience: c.ExpectedAudience,
		JWKSEndpoint:     c.KCJWKSEndpoint,
		ReplayCache:      newInMemoryReplayCache(),
		WorkloadID:       c.WorkloadID,
		Audit:            apiAudit,
	})

	srv := &server{
		log:    log,
		authzn: authzn,
		db:     dbPool,
		mw:     mw,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.healthz)
	mux.HandleFunc("/readyz", srv.readyz(c.KCJWKSEndpoint))
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/api/me", mw.Wrap(http.HandlerFunc(srv.getMe)))
	mux.Handle("/api/document/", mw.Wrap(http.HandlerFunc(srv.documentRouter)))

	httpSrv := &http.Server{
		Addr:              c.ListenAddr,
		Handler:           otelhttp.NewHandler(mux, "helloworld-backend"),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}

	idleClosed := make(chan struct{})
	go func() {
		sigs := make(chan os.Signal, 1)
		signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
		<-sigs
		log.Info("shutdown signal received, draining")
		ctx, cancel := context.WithTimeout(context.Background(), c.ShutdownGrace)
		defer cancel()
		_ = httpSrv.Shutdown(ctx)
		close(idleClosed)
	}()

	log.Info("listening", "addr", c.ListenAddr)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http server failed", "err", err)
		os.Exit(1)
	}
	<-idleClosed
}

func getenv(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		slog.Default().Error("required env var missing", "var", k)
		os.Exit(1)
	}
	return v
}
