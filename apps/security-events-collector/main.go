// security-events-collector — webhook receiver for guardrail-bypass events.
//
// Wire contract: docs/02-decisions/0013-outbound-secrets-no-env.md § 10
// (Inbound webhook receiver authentication) and the Phase 6b-2 prompt
// § Section 8 (event schema).
//
// Endpoints
//
//	POST /v1/secrets/guardrail/bypass    accept one event (auth required)
//	GET  /healthz                         liveness (always 200)
//	GET  /ready                           readiness (always 200; no deps)
//
// The collector is intentionally dependency-light. It reuses
// apps/lib/api-auth/ for inbound JWT validation (covers both SPIFFE-SVID
// in-cluster callers and Keycloak-issued out-of-cluster CI tokens), then
// overrides the payload-claimed `actor` with the verified caller identity
// before writing the event to a JSON-line sink. Phase 7b reads those
// JSON-lines via Promtail and ingests into Loki.
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

	apiauth "github.com/secforge/lib/api-auth"
)

type cfg struct {
	ListenAddr       string
	Issuer           string
	Audience         string
	JWKSEndpoint     string
	WorkloadID       string
	ShutdownGrace    time.Duration
}

func loadCfg() (cfg, error) {
	c := cfg{
		ListenAddr:    getenv("COLLECTOR_LISTEN_ADDR", ":8080"),
		ShutdownGrace: 15 * time.Second,
	}
	c.Issuer = mustEnv("COLLECTOR_ISSUER")
	c.Audience = mustEnv("COLLECTOR_AUDIENCE")
	c.JWKSEndpoint = mustEnv("COLLECTOR_JWKS_ENDPOINT")
	c.WorkloadID = mustEnv("COLLECTOR_WORKLOAD_ID")
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
	log.Info("starting", "issuer", c.Issuer, "audience", c.Audience)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	mw := apiauth.NewMiddleware(apiauth.MiddlewareConfig{
		Issuer:           c.Issuer,
		ExpectedAudience: c.Audience,
		JWKSEndpoint:     c.JWKSEndpoint,
		ReplayCache:      noopReplayCache{},
		WorkloadID:       c.WorkloadID,
	})

	h := &handler{
		mw:   mw,
		sink: newStdoutSink(os.Stdout),
		log:  log,
		now:  time.Now,
	}

	mux := http.NewServeMux()
	mux.Handle("POST /v1/secrets/guardrail/bypass", h)
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /ready", handleHealthz)

	srv := &http.Server{
		Addr:              c.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

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

// noopReplayCache satisfies apiauth.ReplayCache without state. The collector
// does not require DPoP replay protection at 6b-2 — events are append-only
// and idempotent on the consumer side. If/when DPoP becomes a hard
// requirement (future ADR), swap this for the Valkey-backed implementation
// helloworld-bff uses.
type noopReplayCache struct{}

func (noopReplayCache) SeenWithin(ctx context.Context, jti string, window time.Duration) (bool, error) {
	return false, nil
}
