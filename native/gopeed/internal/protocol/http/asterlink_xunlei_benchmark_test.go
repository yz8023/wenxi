package http

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

// This local fixture models one slow request, not Xunlei's public CDN speed.
func BenchmarkXunleiSlowTail100MiB(b *testing.B) {
	const size = 100 * 1024 * 1024
	const workers = 64
	const initialChunk = size / workers
	const tail = 768 * 1024
	data := make([]byte, size)
	for i := range data {
		data[i] = byte((i*31 + i/257) % 251)
	}
	b.SetBytes(size)
	b.StopTimer()
	for i := 0; i < b.N; i++ {
		prefixSent := make(chan struct{})
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var first, last int
			if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= size {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			xunleiResponse(w, first, last, size)
			w.(http.Flusher).Flush()
			if first == 0 && last == 0 {
				_, _ = w.Write(data[:1])
				return
			}
			if first == 0 && last == initialChunk-1 {
				prefix := initialChunk - tail
				if _, err := w.Write(data[:prefix]); err != nil {
					return
				}
				w.(http.Flusher).Flush()
				close(prefixSent)
				for start := prefix; start <= last; start += 16 * 1024 {
					select {
					case <-time.After(40 * time.Millisecond):
					case <-r.Context().Done():
						return
					}
					if _, err := w.Write(data[start:min(start+16*1024, last+1)]); err != nil {
						return
					}
					w.(http.Flusher).Flush()
				}
				return
			}
			// Give the slow request time to publish its downloaded prefix before
			// any worker becomes idle. Only the remaining tail needs help.
			if first%initialChunk == 0 && last-first+1 == initialChunk {
				select {
				case <-prefixSent:
				case <-r.Context().Done():
					return
				}
				select {
				case <-time.After(100 * time.Millisecond):
				case <-r.Context().Done():
					return
				}
			}
			_, _ = w.Write(data[first : last+1])
		}))
		f := buildFetcher()
		if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
			b.Fatal(err)
		}
		if err := f.Create(&base.Options{Name: "slow-tail.bin", Path: b.TempDir(), Extra: &fhttp.OptsExtra{Connections: workers, ConnectionProfile: "xunlei"}}); err != nil {
			b.Fatal(err)
		}
		b.StartTimer()
		if err := f.Start(); err != nil {
			b.Fatal(err)
		}
		if err := f.Wait(); err != nil {
			b.Fatal(err)
		}
		b.StopTimer()
		got, err := os.ReadFile(f.Meta().SingleFilepath())
		if err != nil || !bytes.Equal(got, data) {
			b.Fatal("downloaded file differs from the fixture")
		}
		_ = f.Close()
		server.Close()
	}
}
