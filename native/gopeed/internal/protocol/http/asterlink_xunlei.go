package http

import (
	"context"
	"sync"
	"time"
)

const xunleiBusyConnections = 8
const xunleiBusyPeriod = 2 * time.Minute

type xunleiHost struct {
	active, users int
	busyUntil     time.Time
	changed       chan struct{}
}

var xunleiHosts = struct {
	sync.Mutex
	entries map[string]*xunleiHost
}{entries: make(map[string]*xunleiHost)}

func xunleiHostLocked(host string) *xunleiHost {
	now := time.Now()
	for key, entry := range xunleiHosts.entries {
		if entry.users == 0 && !entry.busyUntil.After(now) {
			delete(xunleiHosts.entries, key)
		}
	}
	entry := xunleiHosts.entries[host]
	if entry == nil {
		entry = &xunleiHost{changed: make(chan struct{})}
		xunleiHosts.entries[host] = entry
	}
	return entry
}

// Healthy nodes retain the user's requested parallelism. An overloaded node
// gets a smaller shared window for retries and subsequent files on that host.
// In-flight requests keep their slots, so a retry cannot pile onto that burst.
func limitXunleiHost(host string) {
	xunleiHosts.Lock()
	defer xunleiHosts.Unlock()
	xunleiHostLocked(host).busyUntil = time.Now().Add(xunleiBusyPeriod)
}

func acquireXunleiConnection(ctx context.Context, host string) (func(), error) {
	xunleiHosts.Lock()
	entry := xunleiHostLocked(host)
	entry.users++
	for {
		if err := ctx.Err(); err != nil {
			entry.users--
			if entry.users == 0 && !entry.busyUntil.After(time.Now()) {
				delete(xunleiHosts.entries, host)
			}
			xunleiHosts.Unlock()
			return nil, err
		}
		limit := 512
		if entry.busyUntil.After(time.Now()) {
			limit = xunleiBusyConnections
		}
		if entry.active < limit {
			entry.active++
			xunleiHosts.Unlock()
			break
		}
		changed := entry.changed
		var timer *time.Timer
		var expired <-chan time.Time
		if remaining := time.Until(entry.busyUntil); remaining > 0 {
			timer = time.NewTimer(remaining)
			expired = timer.C
		}
		xunleiHosts.Unlock()
		select {
		case <-ctx.Done():
		case <-changed:
		case <-expired:
		}
		if timer != nil {
			timer.Stop()
		}
		xunleiHosts.Lock()
	}
	freeHost := func() {
		xunleiHosts.Lock()
		entry.active--
		entry.users--
		close(entry.changed)
		entry.changed = make(chan struct{})
		if entry.users == 0 && !entry.busyUntil.After(time.Now()) {
			delete(xunleiHosts.entries, host)
		}
		xunleiHosts.Unlock()
	}
	freeBudget, err := acquireConnection(ctx, host)
	if err != nil {
		freeHost()
		return nil, err
	}
	return func() {
		freeBudget()
		freeHost()
	}, nil
}
