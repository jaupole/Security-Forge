package secrets

import (
	"sync"
	"time"
)

// kvCache is a TTL-based key/value cache for decoded KV-v2 payloads,
// keyed by full OpenBao path. Concurrent-safe.
//
// Cache values are decoded data maps (map[string]string), not raw
// response bytes — decode happens once per path on miss; subsequent
// hits skip JSON parsing.
//
// Phase 6b-2 caveat: cached values are plaintext for the TTL duration.
// This is the cost of caching outbound credentials. Phase 7 monitoring
// surfaces cache hit rate so the operator can judge whether the TTL is
// well-tuned for each integration.
type kvCache struct {
	mu      sync.RWMutex
	entries map[string]cacheEntry
	ttl     time.Duration
	now     func() time.Time
}

type cacheEntry struct {
	data    map[string]string
	expires time.Time
}

func newKVCache(ttl time.Duration) *kvCache {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &kvCache{
		entries: make(map[string]cacheEntry),
		ttl:     ttl,
		now:     time.Now,
	}
}

// get returns the cached entry for key if present and unexpired.
// On expiry the entry is left in place and the next put overwrites it.
func (c *kvCache) get(key string) (map[string]string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	e, ok := c.entries[key]
	if !ok || c.now().After(e.expires) {
		return nil, false
	}
	return e.data, true
}

// put stores data under key with the cache's configured TTL.
func (c *kvCache) put(key string, data map[string]string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = cacheEntry{
		data:    data,
		expires: c.now().Add(c.ttl),
	}
}

// clear evicts every entry. Called by Client.Close.
func (c *kvCache) clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.entries {
		delete(c.entries, k)
	}
}
