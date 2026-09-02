package provenance

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"time"
)

// Cache memoises verification results.
//
// Verifying an attestation means a registry round trip, a certificate chain
// walk and a transparency-log check. Doing that on every admission is not a
// tuning problem, it is a design error: a Deployment rolling twenty replicas
// would pay for it twenty times while the API server waits.
//
// Both outcomes are cached, successes and failures. Caching only successes
// would leave the expensive path, an image that is going to be rejected, uncached,
// and a crash-looping workload would hammer the registry for as long as it kept
// retrying.
type Cache struct {
	ttl     time.Duration
	failTTL time.Duration
	maxSize int
	now     func() time.Time
	mu      sync.Mutex
	entries map[string]cacheEntry
}

type cacheEntry struct {
	result  Result
	err     error
	expires time.Time
}

// NewCache returns a Cache. A zero or negative ttl disables caching entirely,
// which is what the benchmarks in F5 use as a baseline.
func NewCache(ttl, failTTL time.Duration, maxSize int) *Cache {
	return &Cache{
		ttl:     ttl,
		failTTL: failTTL,
		maxSize: maxSize,
		now:     time.Now,
		entries: make(map[string]cacheEntry),
	}
}

// VerifyFunc is the work a Cache wraps.
type VerifyFunc func(ctx context.Context, imageRef string, want Identity) (Result, error)

// Do returns a cached result for this image and identity, or calls verify.
//
// The key covers the identity as well as the image. The same image is legitimately
// trusted by one workload and refused for another, and a cache keyed only by
// digest would let the first workload's success answer the second one's question.
func (c *Cache) Do(ctx context.Context, imageRef string, want Identity, verify VerifyFunc) (Result, bool, error) {
	if c == nil || c.ttl <= 0 {
		result, err := verify(ctx, imageRef, want)
		return result, false, err
	}

	key := cacheKey(imageRef, want)

	c.mu.Lock()
	entry, ok := c.entries[key]
	if ok && c.now().Before(entry.expires) {
		c.mu.Unlock()
		return entry.result, true, entry.err
	}
	c.mu.Unlock()

	// Deliberately not holding the lock across verification. Two admissions for
	// the same image may both verify it, which wastes one round trip. Serialising
	// them behind a mutex would instead make every admission for every other
	// image wait for this one, which is far worse.
	result, err := verify(ctx, imageRef, want)

	ttl := c.ttl
	if err != nil {
		ttl = c.failTTL
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	c.evictLocked()
	c.entries[key] = cacheEntry{result: result, err: err, expires: c.now().Add(ttl)}
	return result, false, err
}

// evictLocked drops expired entries, and if that was not enough to get under
// the size limit, clears the cache.
//
// Clearing wholesale rather than evicting the least recently used is a
// deliberate simplification: the cost of a miss here is one verification, the
// entries are small, and an LRU is a data structure to get wrong. If the numbers
// in F5 say otherwise, this is the place to change.
func (c *Cache) evictLocked() {
	if len(c.entries) < c.maxSize {
		return
	}
	now := c.now()
	for key, entry := range c.entries {
		if now.After(entry.expires) {
			delete(c.entries, key)
		}
	}
	if len(c.entries) >= c.maxSize {
		c.entries = make(map[string]cacheEntry)
	}
}

// Len reports how many entries are held. For tests and metrics.
func (c *Cache) Len() int {
	if c == nil {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.entries)
}

// cacheKey hashes the image reference together with every field of the identity
// that can change the answer.
func cacheKey(imageRef string, want Identity) string {
	h := sha256.New()
	for _, part := range []string{
		imageRef,
		want.Issuer,
		want.Builder,
		want.SourceRepository,
		want.WorkflowPath,
		want.WorkflowRef,
	} {
		// The length prefix keeps ("ab", "c") from hashing the same as ("a", "bc").
		_, _ = h.Write([]byte{byte(len(part) >> 8), byte(len(part))})
		_, _ = h.Write([]byte(part))
	}
	return hex.EncodeToString(h.Sum(nil))
}
