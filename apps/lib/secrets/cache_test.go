package secrets

import (
	"sync"
	"testing"
	"time"
)

func TestKVCache_PutAndGet(t *testing.T) {
	c := newKVCache(time.Minute)
	c.put("a/b", map[string]string{"k": "v"})

	got, hit := c.get("a/b")
	if !hit {
		t.Fatalf("expected hit")
	}
	if got["k"] != "v" {
		t.Fatalf("got[k] = %q, want v", got["k"])
	}
}

func TestKVCache_MissOnUnknown(t *testing.T) {
	c := newKVCache(time.Minute)
	if _, hit := c.get("never-set"); hit {
		t.Fatalf("expected miss")
	}
}

func TestKVCache_TTLExpiry(t *testing.T) {
	c := newKVCache(time.Minute)
	// Inject a controllable clock.
	now := time.Now()
	c.now = func() time.Time { return now }

	c.put("path", map[string]string{"f": "v"})

	// Within TTL: hit.
	if _, hit := c.get("path"); !hit {
		t.Fatalf("within TTL: expected hit")
	}

	// Advance past TTL: miss.
	now = now.Add(2 * time.Minute)
	if _, hit := c.get("path"); hit {
		t.Fatalf("past TTL: expected miss")
	}
}

func TestKVCache_DefaultTTLOnZero(t *testing.T) {
	c := newKVCache(0)
	if c.ttl != 5*time.Minute {
		t.Fatalf("default TTL = %v, want 5m", c.ttl)
	}
}

func TestKVCache_Clear(t *testing.T) {
	c := newKVCache(time.Minute)
	c.put("a", map[string]string{"k": "v"})
	c.put("b", map[string]string{"k": "v"})

	c.clear()

	if _, hit := c.get("a"); hit {
		t.Fatalf("after clear: a should be evicted")
	}
	if _, hit := c.get("b"); hit {
		t.Fatalf("after clear: b should be evicted")
	}
}

func TestKVCache_ConcurrentReadWrite(t *testing.T) {
	c := newKVCache(time.Minute)
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func(i int) {
			defer wg.Done()
			c.put("k", map[string]string{"f": "v"})
		}(i)
		go func() {
			defer wg.Done()
			_, _ = c.get("k")
		}()
	}
	wg.Wait()
}
