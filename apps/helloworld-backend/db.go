package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	libSecrets "github.com/secforge/lib/secrets"
)

// db wraps a *sql.DB with cred-refresh-on-28P01 semantics.
//
// On startup: fetch dynamic creds, open the pool, ping it.
// On 28P01 (password authentication failed): re-fetch creds, swap the pool
// atomically, retry the failing operation once. Per
// docs/01-architecture/10-helloworld-demo.md § Key design decisions #3.
type db struct {
	cfg     cfg
	secrets *libSecrets.Client
	log     *slog.Logger

	mu   sync.RWMutex
	pool *sql.DB
}

func newDB(ctx context.Context, c cfg, secrets *libSecrets.Client, log *slog.Logger) (*db, error) {
	d := &db{cfg: c, secrets: secrets, log: log}
	if err := d.refresh(ctx); err != nil {
		return nil, fmt.Errorf("initial db pool init: %w", err)
	}
	return d, nil
}

// refresh mints fresh creds from OpenBao, opens a new pool, pings it, then
// atomically swaps the held pool. Old pool is closed after the swap.
func (d *db) refresh(ctx context.Context) error {
	cred, err := d.secrets.GetDynamic(ctx, d.cfg.OpenBaoDBRole)
	if err != nil {
		return fmt.Errorf("openbao mint dynamic cred: %w", err)
	}
	dsn := fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=%s",
		cred.Username, cred.Password, d.cfg.DBHost, d.cfg.DBPort, d.cfg.DBName, d.cfg.DBSSLMode,
	)
	newPool, err := sql.Open("pgx", dsn)
	if err != nil {
		return fmt.Errorf("sql.Open: %w", err)
	}
	newPool.SetMaxOpenConns(8)
	newPool.SetMaxIdleConns(2)
	newPool.SetConnMaxLifetime(time.Duration(cred.LeaseDuration-300) * time.Second) // close before lease expiry
	// 30s instead of 5s — Istio Ambient ztunnel HBONE handshake on first
	// pod-to-pod connection in the same namespace can exceed 5s on cold
	// start. Steady-state ping after pool warm is sub-second.
	pingCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := newPool.PingContext(pingCtx); err != nil {
		_ = newPool.Close()
		return fmt.Errorf("db ping: %w", err)
	}

	d.mu.Lock()
	old := d.pool
	d.pool = newPool
	d.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	d.log.Info("db pool refreshed", "lease_id", cred.LeaseID, "lease_duration_s", cred.LeaseDuration)
	return nil
}

// Close shuts down the pool. Safe to call multiple times.
func (d *db) Close() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.pool != nil {
		_ = d.pool.Close()
		d.pool = nil
	}
}

// queryRowWithRetry runs a single-row query and retries once after refreshing
// credentials if Postgres returns SQLSTATE 28P01 (password auth failed).
//
// Returns the *sql.Row from the (possibly second) attempt. If the retry
// also fails for a non-28P01 reason, the error is on the row.
func (d *db) queryRowWithRetry(ctx context.Context, query string, args ...any) *sql.Row {
	d.mu.RLock()
	pool := d.pool
	d.mu.RUnlock()
	row := pool.QueryRowContext(ctx, query, args...)
	// QueryRowContext doesn't return an error directly — it surfaces on Scan.
	// We can't know if it's 28P01 until the caller scans. So expose a
	// scan-with-retry helper instead. Keep this method for API symmetry but
	// callers should prefer scanWithRetry.
	return row
}

// scanWithRetry executes a query and scans the single row; on 28P01,
// refreshes creds and retries once. Returns sql.ErrNoRows verbatim.
func (d *db) scanWithRetry(ctx context.Context, query string, args []any, dst ...any) error {
	if err := d.scanOnce(ctx, query, args, dst...); err == nil {
		return nil
	} else if !is28P01(err) {
		return err
	}
	d.log.Warn("postgres 28P01; refreshing creds and retrying once")
	if rerr := d.refresh(ctx); rerr != nil {
		return fmt.Errorf("28P01 retry: refresh failed: %w (original: %v)", rerr, "28P01")
	}
	return d.scanOnce(ctx, query, args, dst...)
}

func (d *db) scanOnce(ctx context.Context, query string, args []any, dst ...any) error {
	d.mu.RLock()
	pool := d.pool
	d.mu.RUnlock()
	return pool.QueryRowContext(ctx, query, args...).Scan(dst...)
}

// execWithRetry runs a non-query statement with the same 28P01 retry
// behavior. Returns the rows-affected count from the (possibly second) attempt.
func (d *db) execWithRetry(ctx context.Context, query string, args ...any) (int64, error) {
	rows, err := d.execOnce(ctx, query, args...)
	if err == nil {
		return rows, nil
	}
	if !is28P01(err) {
		return 0, err
	}
	d.log.Warn("postgres 28P01 on exec; refreshing creds and retrying once")
	if rerr := d.refresh(ctx); rerr != nil {
		return 0, fmt.Errorf("28P01 retry: refresh failed: %w", rerr)
	}
	return d.execOnce(ctx, query, args...)
}

func (d *db) execOnce(ctx context.Context, query string, args ...any) (int64, error) {
	d.mu.RLock()
	pool := d.pool
	d.mu.RUnlock()
	res, err := pool.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// is28P01 returns true if the error message matches Postgres SQLSTATE
// 28P01 (invalid_password / password_authentication_failed). pgx surfaces
// this either as a *pgconn.PgError or as a connection error containing
// the SQLSTATE; both cases are handled by string match for portability.
func is28P01(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "SQLSTATE 28P01") || strings.Contains(s, "password authentication failed")
}

// Sentinel for sql.ErrNoRows so callers don't have to import database/sql.
var ErrNoRows = errors.New("no rows")
