package main

// Valkey-backed session store. Schema fixed in
// docs/01-architecture/04-bff-pattern.md §"Valkey session schema".
//
// Per ADR-0013 (no env-borne credentials), the Valkey AUTH password is
// fetched from OpenBao at `secret/data/apps/helloworld-bff/valkey:password`
// via apps/lib/secrets/. The store mirrors helloworld-backend/db.go's
// 28P01 pattern: on Valkey auth failure (NOAUTH / WRONGPASS) the store
// re-fetches the password from OpenBao, opens a fresh client, and
// retries the failing operation once. Operator-backlog #13 closeout.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	libSecrets "github.com/secforge/lib/secrets"
)

const (
	sessionKeyPrefix     = "bff:session:"
	loginKeyPrefix       = "bff:login:"
	refreshLockSuffix    = ":refresh-lock"
	idleTTL              = 30 * time.Minute
	loginTTL             = 15 * time.Minute
	refreshLockTTL       = 5 * time.Second
	refreshLockWaitTotal = 4 * time.Second
	refreshLockPoll      = 50 * time.Millisecond
	schemaVersion        = 1

	// Valkey integration name (matches the OpenBao KV path under the
	// outbound-secrets Client's templated `secret/data/apps/<app>/<integration>`
	// pattern from ADR-0013 § 1).
	valkeyIntegration = "valkey"
	valkeyField       = "password"
)

type sessionStore struct {
	secrets *libSecrets.Client
	addr    string
	db      int
	log     *slog.Logger

	mu  sync.RWMutex
	rdb *redis.Client
}

type sessionV1 struct {
	V              int    `json:"v"`
	Sub            string `json:"sub"`
	PreferredUser  string `json:"preferred_username"`
	SessionState   string `json:"session_state"`
	AccessToken    string `json:"access_token"`
	RefreshToken   string `json:"refresh_token"`
	IDToken        string `json:"id_token"`
	AccessExp      int64  `json:"access_exp"`
	RefreshExp     int64  `json:"refresh_exp"`
	Scope          string `json:"scope"`
	DPoPJktAtIssue string `json:"dpop_jkt_at_issue"`
	CreatedAt      int64  `json:"created_at"`
	LastSeen       int64  `json:"last_seen"`
}

type loginV1 struct {
	V                  int    `json:"v"`
	PKCEVerifier       string `json:"pkce_verifier"`
	Nonce              string `json:"nonce"`
	RedirectAfterLogin string `json:"redirect_after_login"`
	CreatedAt          int64  `json:"created_at"`
}

func newSessionStore(ctx context.Context, c cfg, secrets *libSecrets.Client, log *slog.Logger) (*sessionStore, error) {
	s := &sessionStore{
		secrets: secrets,
		addr:    c.ValkeyAddr,
		db:      c.ValkeyDB,
		log:     log,
	}
	if err := s.refresh(ctx); err != nil {
		return nil, fmt.Errorf("initial valkey client init: %w", err)
	}
	return s, nil
}

// refresh fetches the current Valkey password from OpenBao, opens a
// fresh client, pings it, and atomically swaps the held client. The
// previous client is closed after the swap. Mirrors db.refresh in
// helloworld-backend/db.go.
func (s *sessionStore) refresh(ctx context.Context) error {
	pwSecret, err := s.secrets.GetField(ctx, valkeyIntegration, valkeyField)
	if err != nil {
		return fmt.Errorf("openbao fetch valkey password: %w", err)
	}
	var pw string
	if err := pwSecret.Use(func(b []byte) error {
		pw = string(b)
		return nil
	}); err != nil {
		return fmt.Errorf("valkey password unwrap: %w", err)
	}

	newClient := redis.NewClient(&redis.Options{
		Addr:     s.addr,
		Password: pw,
		DB:       s.db,
	})
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := newClient.Ping(pingCtx).Err(); err != nil {
		_ = newClient.Close()
		return fmt.Errorf("valkey ping after refresh: %w", err)
	}

	s.mu.Lock()
	old := s.rdb
	s.rdb = newClient
	s.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	s.log.Info("valkey client refreshed", "path", "apps/helloworld-bff/"+valkeyIntegration)
	return nil
}

// client returns the currently-held redis client under read lock.
func (s *sessionStore) client() *redis.Client {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rdb
}

// doWithRetry runs fn against the current client; on Valkey auth failure
// (WRONGPASS / NOAUTH) it refreshes the password from OpenBao + reopens
// the client and retries fn once. Mirrors db.scanWithRetry's shape.
func (s *sessionStore) doWithRetry(ctx context.Context, fn func(rdb *redis.Client) error) error {
	if err := fn(s.client()); err == nil {
		return nil
	} else if !isAuthFailure(err) {
		return err
	}
	s.log.Warn("valkey auth failure; refreshing password and retrying once")
	if rerr := s.refresh(ctx); rerr != nil {
		return fmt.Errorf("auth retry: refresh failed: %w", rerr)
	}
	return fn(s.client())
}

func (s *sessionStore) ping(ctx context.Context) error {
	return s.doWithRetry(ctx, func(rdb *redis.Client) error {
		return rdb.Ping(ctx).Err()
	})
}

// newOpaqueID returns 32 random bytes base64url-encoded — the cookie value.
func newOpaqueID() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// Login flow store.

func (s *sessionStore) putLogin(ctx context.Context, state string, l loginV1) error {
	l.V = schemaVersion
	if l.CreatedAt == 0 {
		l.CreatedAt = time.Now().Unix()
	}
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	return s.doWithRetry(ctx, func(rdb *redis.Client) error {
		return rdb.Set(ctx, loginKeyPrefix+state, b, loginTTL).Err()
	})
}

func (s *sessionStore) takeLogin(ctx context.Context, state string) (loginV1, error) {
	var l loginV1
	err := s.doWithRetry(ctx, func(rdb *redis.Client) error {
		v, err := rdb.GetDel(ctx, loginKeyPrefix+state).Bytes()
		if err != nil {
			return err
		}
		if err := json.Unmarshal(v, &l); err != nil {
			return err
		}
		if l.V != schemaVersion {
			return fmt.Errorf("login schema version %d != %d", l.V, schemaVersion)
		}
		return nil
	})
	return l, err
}

// Session store.

func (s *sessionStore) put(ctx context.Context, sid string, sv sessionV1) error {
	sv.V = schemaVersion
	if sv.CreatedAt == 0 {
		sv.CreatedAt = time.Now().Unix()
	}
	sv.LastSeen = time.Now().Unix()
	b, err := json.Marshal(sv)
	if err != nil {
		return err
	}
	ttl := sessionTTL(sv)
	return s.doWithRetry(ctx, func(rdb *redis.Client) error {
		return rdb.Set(ctx, sessionKeyPrefix+sid, b, ttl).Err()
	})
}

func (s *sessionStore) get(ctx context.Context, sid string) (sessionV1, error) {
	var sv sessionV1
	err := s.doWithRetry(ctx, func(rdb *redis.Client) error {
		v, err := rdb.Get(ctx, sessionKeyPrefix+sid).Bytes()
		if err != nil {
			return err
		}
		if err := json.Unmarshal(v, &sv); err != nil {
			return err
		}
		if sv.V != schemaVersion {
			return fmt.Errorf("session schema version %d != %d", sv.V, schemaVersion)
		}
		return nil
	})
	return sv, err
}

func (s *sessionStore) touch(ctx context.Context, sid string, sv sessionV1) error {
	return s.doWithRetry(ctx, func(rdb *redis.Client) error {
		return rdb.Expire(ctx, sessionKeyPrefix+sid, sessionTTL(sv)).Err()
	})
}

func (s *sessionStore) del(ctx context.Context, sid string) error {
	return s.doWithRetry(ctx, func(rdb *redis.Client) error {
		return rdb.Del(ctx, sessionKeyPrefix+sid).Err()
	})
}

// sessionTTL caps idle TTL at refresh_exp.
func sessionTTL(sv sessionV1) time.Duration {
	// RefreshExp == 0 means Keycloak issued an offline refresh token
	// (refresh_expires_in: 0 in the token response — offline tokens
	// don't expire by themselves). Don't treat that as "already expired";
	// fall back to the idle TTL so the session lives a normal lifetime.
	if sv.RefreshExp == 0 {
		return idleTTL
	}
	maxRemain := time.Until(time.Unix(sv.RefreshExp, 0))
	if maxRemain < 0 {
		return 1 * time.Second // expire immediately
	}
	if maxRemain < idleTTL {
		return maxRemain
	}
	return idleTTL
}

// withRefreshLock acquires the single-flight refresh lock for sid. The
// loser path polls the session record for an updated access token and
// returns the refreshed session. Both paths may return an error.
//
// SetNX + Del here are NOT wrapped in doWithRetry's auth-retry path —
// they're called from refresh-token paths that re-enter the store via
// `get`, which IS wrapped. A WRONGPASS at this layer is rare (the store
// has been operating just fine moments before) and any caller that hits
// it gets the error and surfaces upward, where the next session op via
// doWithRetry refreshes naturally.
func (s *sessionStore) withRefreshLock(ctx context.Context, sid string, doRefresh func() (sessionV1, error)) (sessionV1, error) {
	rdb := s.client()
	lockKey := sessionKeyPrefix + sid + refreshLockSuffix
	ok, err := rdb.SetNX(ctx, lockKey, "1", refreshLockTTL).Result()
	if err != nil {
		return sessionV1{}, err
	}
	if ok {
		defer rdb.Del(ctx, lockKey)
		return doRefresh()
	}
	deadline := time.Now().Add(refreshLockWaitTotal)
	for time.Now().Before(deadline) {
		time.Sleep(refreshLockPoll)
		sv, err := s.get(ctx, sid)
		if err != nil {
			continue
		}
		if time.Until(time.Unix(sv.AccessExp, 0)) > 30*time.Second {
			return sv, nil
		}
	}
	return sessionV1{}, errors.New("refresh lock wait timed out")
}

// isAuthFailure returns true if err is a Valkey/Redis AUTH-failure
// error. Static-secret rotation analogue of helloworld-backend/db.go's
// is28P01 — the BFF treats WRONGPASS / NOAUTH as the trigger to re-fetch
// the password from OpenBao and reconnect.
func isAuthFailure(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "WRONGPASS") ||
		strings.Contains(s, "NOAUTH") ||
		strings.Contains(s, "invalid password")
}
