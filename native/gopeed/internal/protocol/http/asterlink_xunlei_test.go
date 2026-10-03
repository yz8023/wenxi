package http

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func xunleiRange(t *testing.T, r *http.Request, size int) (first, last int, ok bool) {
	t.Helper()
	if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= size {
		t.Errorf("invalid download range: %q", r.Header.Get("Range"))
		return 0, 0, false
	}
	return first, last, true
}

func xunleiResponse(w http.ResponseWriter, first, last, size int) {
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, size))
	w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
	w.WriteHeader(http.StatusPartialContent)
}

func xunleiFetcher(t *testing.T, url string, workers int) *Fetcher {
	t.Helper()
	f := buildFetcher()
	t.Cleanup(func() { _ = f.Close() })
	if err := f.Resolve(&base.Request{URL: url}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: "range-check.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: workers, ConnectionProfile: "xunlei"}}); err != nil {
		t.Fatal(err)
	}
	return f
}

func verifyXunleiDownload(t *testing.T, f *Fetcher, want []byte) {
	t.Helper()
	if err := f.Wait(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || !bytes.Equal(got, want) {
		t.Fatal("range handoff lost or overwrote file bytes")
	}
	if got := f.Progress(); len(got) != 1 || got[0] != int64(len(want)) {
		t.Fatalf("downloaded bytes = %v, want %d", got, len(want))
	}
	spans := f.ReadableRanges()
	if len(spans) != 1 || spans[0] != [2]int64{0, int64(len(want))} {
		t.Fatalf("readable ranges do not cover the complete file: %v", spans)
	}
	if active, _ := f.ConnectionCounts(); active != 0 {
		t.Fatalf("completed task still has %d active requests", active)
	}
}

func TestXunleiRangesStartBeforeFirstResponseHeaders(t *testing.T) {
	const workers = 64
	data := bytes.Repeat([]byte("range-data-012345"), 1024*1024)
	arrived := make(chan struct{})
	var requests atomic.Int32
	var serialized atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first != 0 || last != 0 {
			if requests.Add(1) == workers {
				close(arrived)
			}
			select {
			case <-arrived:
			case <-time.After(2 * time.Second):
				serialized.Store(true)
			case <-r.Context().Done():
				return
			}
		}
		xunleiResponse(w, first, last, len(data))
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := xunleiFetcher(t, server.URL, workers)
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if serialized.Load() {
		t.Error("Xunlei ranges waited for the first response headers")
	}
	if _, total := f.ConnectionCounts(); total != workers {
		t.Errorf("configured %d connections but created %d", workers, total)
	}
}

func TestXunleiIdleWorkerHelpsSubMiBTail(t *testing.T) {
	const chunkSize = 1024 * 1024
	data := make([]byte, 4*chunkSize)
	for i := range data {
		data[i] = byte((i*31 + i/257) % 251)
	}
	helpArrived := make(chan struct{})
	var once sync.Once
	var helped atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		xunleiResponse(w, first, last, len(data))
		if first == 0 && last == chunkSize-1 {
			// Send a prefix, leaving less than 1 MiB on one slow connection.
			_, _ = w.Write(data[:32*1024])
			w.(http.Flusher).Flush()
			select {
			case <-helpArrived:
				helped.Store(true)
			case <-time.After(2 * time.Second):
			case <-r.Context().Done():
				return
			}
			_, _ = w.Write(data[32*1024 : last+1])
			return
		}
		if first > 0 && first < chunkSize && last < chunkSize {
			once.Do(func() { close(helpArrived) })
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := xunleiFetcher(t, server.URL, 4)
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if !helped.Load() {
		t.Error("idle workers left a sub-MiB tail on a slow connection")
	}
}

func TestXunleiPauseAndRestoreAfterTailHandoff(t *testing.T) {
	const chunkSize = 1024 * 1024
	data := make([]byte, 4*chunkSize)
	for i := range data {
		data[i] = byte((i*17 + i/193) % 251)
	}
	handoff := make(chan struct{})
	var once sync.Once
	var finish atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		xunleiResponse(w, first, last, len(data))
		w.(http.Flusher).Flush()
		if !finish.Load() && first < chunkSize && last > 0 {
			if first == 0 {
				_, _ = w.Write(data[:32*1024])
				w.(http.Flusher).Flush()
			} else {
				once.Do(func() { close(handoff) })
			}
			<-r.Context().Done()
			return
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := xunleiFetcher(t, server.URL, 4)
	defer f.Close()
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-handoff:
	case <-time.After(3 * time.Second):
		t.Fatal("no tail handoff before pause")
	}
	// Snapshot while ranges can still publish progress, then pause all writes.
	manager := &FetcherManager{}
	live, err := manager.Store(f)
	if err != nil {
		t.Fatal(err)
	}
	encodedLive, err := json.Marshal(live)
	if err != nil {
		t.Fatal(err)
	}
	_ = f.Stats()
	_ = f.Progress()
	if err := f.Pause(); err != nil {
		t.Fatal(err)
	}
	if active, _ := f.ConnectionCounts(); active != 0 {
		t.Fatalf("paused task has %d active requests", active)
	}
	checkpoint, err := manager.Store(f)
	if err != nil {
		t.Fatal(err)
	}
	var accounted int64
	for _, c := range checkpoint.(*fetcherData).Connections {
		accounted += c.Downloaded + c.Chunk.remain()
	}
	if accounted != int64(len(data)) {
		t.Fatalf("checkpoint accounts for %d bytes, want %d", accounted, len(data))
	}
	encoded, err := json.Marshal(checkpoint)
	if err != nil {
		t.Fatal(err)
	}
	value, restore := manager.Restore()
	if err := json.Unmarshal(encoded, value); err != nil {
		t.Fatal(err)
	}
	resumed := restore(f.Meta(), value).(*Fetcher)
	resumed.Setup(f.ctl)
	defer resumed.Close()
	finish.Store(true)
	if err := resumed.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, resumed, data)
	if again, err := json.Marshal(live); err != nil || !bytes.Equal(again, encodedLive) {
		t.Fatal("a stored checkpoint was modified by later range activity")
	}
}

func TestXunleiOverloadCountsExistingRequestsAndCancelsWaiters(t *testing.T) {
	const host = "busy-xunlei.invalid"
	releases := make([]func(), 16)
	for i := range releases {
		var err error
		releases[i], err = acquireProfileConnection(context.Background(), host, "xunlei")
		if err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		for _, free := range releases {
			if free != nil {
				free()
			}
		}
		xunleiHosts.Lock()
		delete(xunleiHosts.entries, host)
		xunleiHosts.Unlock()
	}()
	limitXunleiHost(host)
	for i := 0; i < 8; i++ {
		releases[i]()
		releases[i] = nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	if free, err := acquireProfileConnection(ctx, host, "xunlei"); err == nil {
		free()
		t.Fatal("retry was admitted while eight existing requests were active")
	}
	// A second task on the host must share the same reduced window.
	releases[8]()
	releases[8] = nil
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	free, err := acquireProfileConnection(ctx, host, "xunlei")
	if err != nil {
		t.Fatal("cancelled waiter kept the newly available slot")
	}
	free()
	// The busy host must not reduce another node's available connections.
	other, err := acquireProfileConnection(context.Background(), "healthy-xunlei.invalid", "xunlei")
	if err != nil {
		t.Fatal(err)
	}
	other()
}

func TestXunleiBusyHostWindowExpires(t *testing.T) {
	const host = "recovering-xunlei.invalid"
	limitXunleiHost(host)
	xunleiHosts.Lock()
	xunleiHosts.entries[host].busyUntil = time.Now().Add(-time.Second)
	xunleiHosts.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var releases []func()
	defer func() {
		for _, free := range releases {
			free()
		}
	}()
	for i := 0; i < 16; i++ {
		free, err := acquireProfileConnection(ctx, host, "xunlei")
		if err != nil {
			t.Fatal("expired node limit suppressed normal parallelism")
		}
		releases = append(releases, free)
	}
}

func TestXunleiBusyHostWindowWakesQueuedRequests(t *testing.T) {
	const host = "queued-xunlei.invalid"
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var releases []func()
	defer func() {
		for _, free := range releases {
			free()
		}
	}()
	for i := 0; i < xunleiBusyConnections; i++ {
		free, err := acquireProfileConnection(ctx, host, "xunlei")
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, free)
	}
	limitXunleiHost(host)
	xunleiHosts.Lock()
	xunleiHosts.entries[host].busyUntil = time.Now().Add(30 * time.Millisecond)
	xunleiHosts.Unlock()
	// Existing streams can remain active beyond the busy period. A queued
	// request must wake when it expires, without requiring one to finish.
	free, err := acquireProfileConnection(ctx, host, "xunlei")
	if err != nil {
		t.Fatal("queued request did not resume when the busy window expired")
	}
	free()
}

func TestXunleiOverloadedNodeRecoversWithBoundedRetry(t *testing.T) {
	const workers = 32
	data := bytes.Repeat([]byte("0123456789abcdef"), 512*1024)
	var active, rejected atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first != 0 || last != 0 {
			count := active.Add(1)
			defer active.Add(-1)
			if count > 8 {
				rejected.Add(1)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			xunleiResponse(w, first, last, len(data))
			w.(http.Flusher).Flush()
			select {
			case <-time.After(150 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		} else {
			xunleiResponse(w, first, last, len(data))
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := xunleiFetcher(t, server.URL, workers)
	defer func() {
		_ = f.Close()
		u, _ := url.Parse(server.URL)
		xunleiHosts.Lock()
		delete(xunleiHosts.entries, u.Host)
		xunleiHosts.Unlock()
	}()
	retries := 1
	f.meta.Opts.Extra.(*fhttp.OptsExtra).RetryLimit = &retries
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if rejected.Load() == 0 {
		t.Fatal("fixture did not exercise an overloaded node")
	}
}
