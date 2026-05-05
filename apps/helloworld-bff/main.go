// helloworld-bff — Backend-for-Frontend for the SecForge platform.
//
// Wire contract: docs/01-architecture/04-bff-pattern.md
//
// Endpoints
//
//	GET  /login              start OIDC PAR + DPoP auth-code flow
//	GET  /callback           OIDC code exchange; sets opaque session cookie
//	POST /logout             local invalidate, best-effort revoke, KC end-session redirect
//	/api/*                   reverse-proxy to backend with Bearer + DPoP injection
//	/*                       reverse-proxy to frontend with CSP nonce request header
//	GET  /healthz            liveness (always 200)
//	GET  /ready              readiness (Valkey + JWKS + OpenBao reachable)
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	libSecrets "github.com/secforge/lib/secrets"
)

// cfg captures every BFF configuration knob, all sourced from env vars.
// Defaults only apply where the value cannot leak across environments.
type cfg struct {
	PublicOrigin   string // e.g. https://app.secforge.local — drives htu canon + cookie scope
	BackendURL     string // upstream API base URL (Phase 9 backend)
	FrontendURL    string // upstream frontend base URL (Phase 9 frontend); blank = no frontend yet
	KCIssuer       string // Keycloak realm issuer URL
	KCClientID     string // OIDC client_id
	ValkeyAddr     string // host:port for Valkey (Redis-compatible)
	ValkeyPassword string // fetched at startup from OpenBao at apps/<bff>/valkey:password
	ValkeyDB       int    // logical DB; default 0
	OpenBaoAddr    string // OpenBao API base, e.g. https://openbao.openbao.svc.cluster.local:8200
	OpenBaoRole    string // jwt-auth role (e.g. helloworld-bff)
	OpenBaoSVIDIn  string // path inside the pod where spiffe-helper wrote the JWT-SVID
	OpenBaoKVPath  string // KV-v2 path holding our private_key_jwt PEM
	ListenAddr     string // :3000 by default
	ShutdownGrace  time.Duration
}

func loadCfg() (cfg, error) {
	c := cfg{
		ListenAddr:    getenv("BFF_LISTEN_ADDR", ":3000"),
		ShutdownGrace: 15 * time.Second,
	}
	c.PublicOrigin = mustEnv("BFF_PUBLIC_ORIGIN")
	c.BackendURL = getenv("BFF_BACKEND_URL", "")
	c.FrontendURL = getenv("BFF_FRONTEND_URL", "")
	c.KCIssuer = mustEnv("BFF_KEYCLOAK_ISSUER")
	c.KCClientID = mustEnv("BFF_KEYCLOAK_CLIENT_ID")
	c.ValkeyAddr = mustEnv("BFF_VALKEY_ADDR")
	// ValkeyPassword is intentionally NOT loaded from an env var.
	// Per ADR-0013 (no env-borne credentials) it's fetched from OpenBao
	// at startup; see main() after newOutboundSecretsClient is constructed.
	c.OpenBaoAddr = mustEnv("BFF_OPENBAO_ADDR")
	c.OpenBaoRole = getenv("BFF_OPENBAO_ROLE", "helloworld-bff")
	c.OpenBaoSVIDIn = getenv("BFF_OPENBAO_SVID_PATH", "/shared/openbao.jwt")
	c.OpenBaoKVPath = getenv("BFF_OPENBAO_KV_PATH", "secret/data/keycloak/clients/helloworld-bff")
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
	log.Info("starting", "public_origin", c.PublicOrigin, "kc_issuer", c.KCIssuer)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// OpenTelemetry tracer. No-op when OTEL_EXPORTER_OTLP_ENDPOINT is unset.
	shutdownTracer, err := initTracer(ctx)
	if err != nil {
		log.Error("tracer init failed", "err", err)
		os.Exit(1)
	}
	defer func() {
		fctx, fcancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer fcancel()
		_ = shutdownTracer(fctx)
	}()

	// Bootstrap the BFF's private_key_jwt PEM from OpenBao via the
	// SPIFFE-bound JWT-SVID. The init container (spiffe-helper) wrote
	// the JWT to disk before we're scheduled; the lib does the
	// auth/jwt/login + KV read.
	bootstrap, err := libSecrets.NewOpenBaoBootstrapper(c.OpenBaoAddr, c.OpenBaoSVIDIn, c.OpenBaoRole, c.OpenBaoKVPath)
	if err != nil {
		log.Error("openbao bootstrapper config", "err", err)
		os.Exit(1)
	}
	clientPriv, err := bootstrap.GetClientKey(ctx)
	if err != nil {
		log.Error("openbao bootstrap failed", "err", err)
		os.Exit(1)
	}

	// DPoP keypair: per-pod, in-memory only. Never leaves the process.
	dpop, err := newDPoP()
	if err != nil {
		log.Error("dpop keypair init failed", "err", err)
		os.Exit(1)
	}
	log.Info("dpop keypair ready", "jkt", dpop.jkt)

	oidc, err := newOIDC(ctx, c, clientPriv)
	if err != nil {
		log.Error("oidc init failed", "err", err)
		os.Exit(1)
	}

	// Phase 6b-2 commit 5: outbound-secrets Client (ADR-0013 § 5). Reuses
	// the same OpenBaoBootstrapper as the private_key_jwt path; the
	// templated OpenBao policy authorizes reads from
	// `secret/data/apps/helloworld-bff/*` for this app's role.
	//
	// Constructed BEFORE the session store because the Valkey AUTH
	// password is fetched from OpenBao via this client (operator-backlog
	// #13 closeout, 2026-05-05).
	osc, err := newOutboundSecretsClient(bootstrap, "helloworld-bff")
	if err != nil {
		log.Error("outbound secrets client init failed", "err", err)
		os.Exit(1)
	}
	log.Info("outbound-secrets client ready", "app", "helloworld-bff", "hardened", true)

	// Operator-backlog #13 (closed 2026-05-05): fetch the Valkey AUTH
	// password from OpenBao at apps/helloworld-bff/valkey:password.
	// Replaces the prior BFF_VALKEY_PASSWORD env var + K8s Secret +
	// secforge.local/legacy-secret-env annotation.
	//
	// The Secret returned by GetField is consumed via Use here so its
	// in-memory residency is bounded to this scope; the redis client
	// stores its own immutable-string copy of the password thereafter
	// (the same boundary every redis-go consumer accepts).
	valkeyPwSecret, err := osc.client.GetField(ctx, "valkey", "password")
	if err != nil {
		log.Error("openbao fetch valkey password failed", "path", "apps/helloworld-bff/valkey", "err", err)
		os.Exit(1)
	}
	if err := valkeyPwSecret.Use(func(b []byte) error {
		c.ValkeyPassword = string(b)
		return nil
	}); err != nil {
		log.Error("valkey password unwrap failed", "err", err)
		os.Exit(1)
	}
	log.Info("valkey password loaded from openbao", "path", "apps/helloworld-bff/valkey")

	sess, err := newSessionStore(ctx, c)
	if err != nil {
		log.Error("session store init failed", "err", err)
		os.Exit(1)
	}

	// Phase 6b-1: api-auth library wiring (apps/lib/api-auth). The bundle
	// holds Middleware (constructed-but-not-routed; see auth.go header),
	// Client (used in proxyToBackend for outbound hops), and Audit (3-site
	// LogHop in proxy.go: inbound edge, outbound attempt, outbound result).
	apiAuth, err := newAPIAuth(c, sess, dpop, clientPriv, dpop.jkt)
	if err != nil {
		log.Error("api-auth init failed", "err", err)
		os.Exit(1)
	}
	log.Info("api-auth ready",
		"audiences", os.Getenv("BFF_AUDIENCE_LIST"),
		"backend_audience", apiAuth.backendAudience,
		"workload_id", apiAuth.workloadID)

	// Phase 6b-2 commit 5: errreport ScrubbingReporter wired into a
	// no-op sink (ADR-0013 § 6). Production code paths invoke errReporter()
	// to capture errors with redaction; Phase 7 swaps the sink without
	// touching consumers.
	initErrReporter(log)

	// Routing.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /ready", handleReady(sess, oidc))
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("GET /login", handleLogin(c, oidc, sess, dpop))
	mux.HandleFunc("GET /auth/callback", handleCallback(c, oidc, sess, dpop))
	mux.HandleFunc("POST /logout", handleLogout(c, oidc, sess))
	mux.HandleFunc("/api/", proxyToBackend(c, oidc, sess, dpop, apiAuth))

	// Feature-gated debug endpoint (ADR-0013 reference adopter). Default
	// OFF; enable per-pod via BFF_ENABLE_ADMIN_TEST_OUTBOUND_SECRET=true.
	// Demonstrates GetField + Secret.Use without ever returning the raw
	// secret value to the client. See admin.go header for the operator-
	// time prerequisite (one-line `bao kv put`).
	if os.Getenv("BFF_ENABLE_ADMIN_TEST_OUTBOUND_SECRET") == "true" {
		mux.HandleFunc("GET /admin/test-outbound-secret", handleAdminTestOutboundSecret(osc, log))
		log.Info("admin test-outbound-secret endpoint enabled (debug)")
	}

	mux.HandleFunc("/", proxyToFrontend(c, sess))

	// otelhttp.NewHandler wraps the chain to emit a span per inbound
	// request and extract any incoming W3C traceparent headers. /metrics
	// scrapes are noisy, so we filter them out of trace data.
	tracedHandler := otelhttp.NewHandler(
		withSecurityHeaders(c, mux),
		"bff",
		otelhttp.WithFilter(func(r *http.Request) bool {
			return r.URL.Path != "/metrics" && r.URL.Path != "/healthz" && r.URL.Path != "/ready"
		}),
	)
	srv := &http.Server{
		Addr:              c.ListenAddr,
		Handler:           tracedHandler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown on SIGTERM.
	go func() {
		log.Info("listening", "addr", c.ListenAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", "err", err)
			cancel()
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-stop:
		log.Info("shutdown signal received")
	case <-ctx.Done():
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), c.ShutdownGrace)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func handleReady(s *sessionStore, o *oidcClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := s.ping(r.Context()); err != nil {
			httpJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "valkey", "detail": err.Error()})
			return
		}
		if err := o.ping(r.Context()); err != nil {
			httpJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "keycloak", "detail": err.Error()})
			return
		}
		httpJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		slog.Error("missing env var", "key", k)
		os.Exit(2)
	}
	return v
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
