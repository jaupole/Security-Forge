package main

import (
	"context"
	"sync"
	"time"
)

// inMemoryReplayCache is the per-pod LRU-by-time DPoP jti replay cache.
//
// Per docs/01-architecture/10-helloworld-demo.md § Key design decisions #6,
// the demo accepts that two backend replicas means a jti could in principle
// be replayed across pods within the iat skew window (60s). Cloud-edition
// migrates to a Valkey-backed shared replay cache.
type inMemoryReplayCache struct {
	mu    sync.Mutex
	seen  map[string]time.Time
	stop  chan struct{}
}

func newInMemoryReplayCache() *inMemoryReplayCache {
	c := &inMemoryReplayCache{
		seen: make(map[string]time.Time),
		stop: make(chan struct{}),
	}
	go c.gc()
	return c
}

// SeenWithin returns true if jti was already inserted within window. Inserts
// jti atomically — the second concurrent call observes true.
func (c *inMemoryReplayCache) SeenWithin(_ context.Context, jti string, window time.Duration) (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	if t, ok := c.seen[jti]; ok && now.Sub(t) < window {
		return true, nil
	}
	c.seen[jti] = now
	return false, nil
}

// gc periodically prunes entries older than 10 minutes (twice the maximum
// reasonable replay window) so the map doesn't grow unbounded.
func (c *inMemoryReplayCache) gc() {
	t := time.NewTicker(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-c.stop:
			return
		case <-t.C:
			cutoff := time.Now().Add(-10 * time.Minute)
			c.mu.Lock()
			for k, v := range c.seen {
				if v.Before(cutoff) {
					delete(c.seen, k)
				}
			}
			c.mu.Unlock()
		}
	}
}
