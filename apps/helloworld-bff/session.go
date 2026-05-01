package main

// Valkey-backed session store. Schema fixed in
// docs/01-architecture/04-bff-pattern.md §"Valkey session schema".

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	sessionKeyPrefix     = "bff:session:"
	loginKeyPrefix       = "bff:login:"
	refreshLockSuffix    = ":refresh-lock"
	idleTTL              = 30 * time.Minute
	loginTTL             = 5 * time.Minute
	refreshLockTTL       = 5 * time.Second
	refreshLockWaitTotal = 4 * time.Second
	refreshLockPoll      = 50 * time.Millisecond
	schemaVersion        = 1
)

type sessionStore struct {
	rdb *redis.Client
}

type sessionV1 struct {
	V                int    `json:"v"`
	Sub              string `json:"sub"`
	PreferredUser    string `json:"preferred_username"`
	SessionState     string `json:"session_state"`
	AccessToken      string `json:"access_token"`
	RefreshToken     string `json:"refresh_token"`
	IDToken          string `json:"id_token"`
	AccessExp        int64  `json:"access_exp"`
	RefreshExp       int64  `json:"refresh_exp"`
	Scope            string `json:"scope"`
	DPoPJktAtIssue   string `json:"dpop_jkt_at_issue"`
	CreatedAt        int64  `json:"created_at"`
	LastSeen         int64  `json:"last_seen"`
}

type loginV1 struct {
	V                  int    `json:"v"`
	PKCEVerifier       string `json:"pkce_verifier"`
	Nonce              string `json:"nonce"`
	RedirectAfterLogin string `json:"redirect_after_login"`
	CreatedAt          int64  `json:"created_at"`
}

func newSessionStore(ctx context.Context, c cfg) (*sessionStore, error) {
	rdb := redis.NewClient(&redis.Options{
		Addr:     c.ValkeyAddr,
		Password: c.ValkeyPassword,
		DB:       c.ValkeyDB,
	})
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("valkey ping: %w", err)
	}
	return &sessionStore{rdb: rdb}, nil
}

func (s *sessionStore) ping(ctx context.Context) error { return s.rdb.Ping(ctx).Err() }

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
	return s.rdb.Set(ctx, loginKeyPrefix+state, b, loginTTL).Err()
}

func (s *sessionStore) takeLogin(ctx context.Context, state string) (loginV1, error) {
	var l loginV1
	v, err := s.rdb.GetDel(ctx, loginKeyPrefix+state).Bytes()
	if err != nil {
		return l, err
	}
	if err := json.Unmarshal(v, &l); err != nil {
		return l, err
	}
	if l.V != schemaVersion {
		return l, fmt.Errorf("login schema version %d != %d", l.V, schemaVersion)
	}
	return l, nil
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
	return s.rdb.Set(ctx, sessionKeyPrefix+sid, b, ttl).Err()
}

func (s *sessionStore) get(ctx context.Context, sid string) (sessionV1, error) {
	var sv sessionV1
	v, err := s.rdb.Get(ctx, sessionKeyPrefix+sid).Bytes()
	if err != nil {
		return sv, err
	}
	if err := json.Unmarshal(v, &sv); err != nil {
		return sv, err
	}
	if sv.V != schemaVersion {
		return sv, fmt.Errorf("session schema version %d != %d", sv.V, schemaVersion)
	}
	return sv, nil
}

func (s *sessionStore) touch(ctx context.Context, sid string, sv sessionV1) error {
	return s.rdb.Expire(ctx, sessionKeyPrefix+sid, sessionTTL(sv)).Err()
}

func (s *sessionStore) del(ctx context.Context, sid string) error {
	return s.rdb.Del(ctx, sessionKeyPrefix+sid).Err()
}

// sessionTTL caps idle TTL at refresh_exp.
func sessionTTL(sv sessionV1) time.Duration {
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
func (s *sessionStore) withRefreshLock(ctx context.Context, sid string, doRefresh func() (sessionV1, error)) (sessionV1, error) {
	lockKey := sessionKeyPrefix + sid + refreshLockSuffix
	ok, err := s.rdb.SetNX(ctx, lockKey, "1", refreshLockTTL).Result()
	if err != nil {
		return sessionV1{}, err
	}
	if ok {
		defer s.rdb.Del(ctx, lockKey)
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
