package provenance

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// counter records how many times the real verification would have run.
type counter struct {
	mu    sync.Mutex
	calls int
	err   error
}

func (c *counter) verify(_ context.Context, imageRef string, _ Identity) (Result, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	return Result{Digest: "sha256:" + imageRef}, c.err
}

func (c *counter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

func identity(repo string) Identity {
	return Identity{
		Issuer:           "https://token.actions.githubusercontent.com",
		Builder:          "https://github.com/Mampiz/provenance-gate/.github/workflows/build-sign.yml@refs/heads/main",
		SourceRepository: repo,
	}
}

func TestCacheServesTheSecondAdmissionFromMemory(t *testing.T) {
	c := NewCache(time.Minute, time.Minute, 100)
	work := &counter{}
	id := identity("https://github.com/Mampiz/my-service")

	for i := range 5 {
		_, hit, err := c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
		if err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
		if i == 0 && hit {
			t.Error("the first call reported a cache hit")
		}
		if i > 0 && !hit {
			t.Errorf("call %d missed the cache", i)
		}
	}

	if work.count() != 1 {
		t.Errorf("verified %d times, expected once: a rolling Deployment would pay this per replica", work.count())
	}
}

func TestCacheKeyCoversTheIdentityNotJustTheImage(t *testing.T) {
	// The same image is legitimately trusted by one workload and refused for
	// another. A cache keyed only by digest would let the first answer the
	// second, which is a way to admit an image that should have been rejected.
	c := NewCache(time.Minute, time.Minute, 100)
	work := &counter{}

	_, _, _ = c.Do(context.Background(), "ghcr.io/x/y:v1", identity("https://github.com/Mampiz/a"), work.verify)
	_, hit, _ := c.Do(context.Background(), "ghcr.io/x/y:v1", identity("https://github.com/Mampiz/b"), work.verify)

	if hit {
		t.Fatal("a different build identity was answered from another one's cache entry")
	}
	if work.count() != 2 {
		t.Errorf("verified %d times, expected 2", work.count())
	}
}

func TestCacheExpires(t *testing.T) {
	c := NewCache(time.Minute, time.Minute, 100)
	clock := time.Now()
	c.now = func() time.Time { return clock }
	work := &counter{}
	id := identity("https://github.com/Mampiz/my-service")

	_, _, _ = c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
	clock = clock.Add(61 * time.Second)
	_, hit, _ := c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)

	if hit {
		t.Fatal("an expired entry was served")
	}
	if work.count() != 2 {
		t.Errorf("verified %d times, expected 2", work.count())
	}
}

func TestCacheRemembersRejectionsToo(t *testing.T) {
	// A crash-looping workload retries forever. If only successes were cached,
	// every retry would be a fresh registry round trip for an image that is
	// going to be refused anyway.
	c := NewCache(time.Minute, 10*time.Second, 100)
	work := &counter{err: errors.New("no attestation")}
	id := identity("https://github.com/Mampiz/my-service")

	for range 3 {
		_, _, err := c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
		if err == nil {
			t.Fatal("a cached failure came back as a success")
		}
	}
	if work.count() != 1 {
		t.Errorf("verified %d times, expected the rejection to be cached", work.count())
	}
}

func TestCacheFailuresExpireSoonerThanSuccesses(t *testing.T) {
	// An image whose attestation has not been pushed yet must become admissible
	// without waiting out the success TTL.
	c := NewCache(time.Hour, 10*time.Second, 100)
	clock := time.Now()
	c.now = func() time.Time { return clock }
	work := &counter{err: errors.New("no attestation")}
	id := identity("https://github.com/Mampiz/my-service")

	_, _, _ = c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
	clock = clock.Add(11 * time.Second)

	work.err = nil
	_, hit, err := c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
	if hit {
		t.Fatal("the failure was still cached after its shorter TTL")
	}
	if err != nil {
		t.Fatalf("the retry should have succeeded: %v", err)
	}
}

func TestCacheDisabledWhenTTLIsZero(t *testing.T) {
	// F5 measures admission latency with and without the cache, so "off" has to
	// mean off rather than a one-entry cache.
	c := NewCache(0, 0, 100)
	work := &counter{}
	id := identity("https://github.com/Mampiz/my-service")

	for range 3 {
		_, hit, _ := c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
		if hit {
			t.Fatal("a disabled cache reported a hit")
		}
	}
	if work.count() != 3 {
		t.Errorf("verified %d times, expected 3", work.count())
	}
}

func TestCacheStaysBounded(t *testing.T) {
	c := NewCache(time.Hour, time.Hour, 10)
	work := &counter{}
	id := identity("https://github.com/Mampiz/my-service")

	for i := range 100 {
		_, _, _ = c.Do(context.Background(), "ghcr.io/x/y:v"+string(rune('a'+i%26))+string(rune('a'+i/26)), id, work.verify)
	}

	if c.Len() > 10 {
		t.Errorf("the cache holds %d entries with a limit of 10: unbounded growth in an admission handler is a memory leak with an audience", c.Len())
	}
}

func TestCacheIsSafeUnderConcurrentAdmissions(t *testing.T) {
	c := NewCache(time.Minute, time.Minute, 100)
	work := &counter{}
	id := identity("https://github.com/Mampiz/my-service")

	var wg sync.WaitGroup
	for range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, _ = c.Do(context.Background(), "ghcr.io/x/y:v1", id, work.verify)
		}()
	}
	wg.Wait()

	if c.Len() != 1 {
		t.Errorf("50 concurrent admissions produced %d entries, expected 1", c.Len())
	}
}
