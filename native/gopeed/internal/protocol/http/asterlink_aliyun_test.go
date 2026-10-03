package http

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestAliyunRangesStartBeforeFirstResponseHeaders(t *testing.T) {
	const workers = 8
	data := bytes.Repeat([]byte("original-file-range-content\n"), 128*1024)
	arrived := make(chan struct{})
	var requests atomic.Int32
	var serialized atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var first, last int
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= len(data) {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first != 0 || last != 0 {
			if requests.Add(1) == workers {
				close(arrived)
			}
			select {
			case <-arrived:
			case <-time.After(time.Second):
				serialized.Store(true)
			case <-r.Context().Done():
				return
			}
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
		w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: "parallel.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: workers, ConnectionProfile: "aliyun"}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	if err := f.Wait(); err != nil {
		t.Fatal(err)
	}
	if serialized.Load() {
		t.Error("other Aliyun ranges waited for the first response headers")
	}
	got, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || !bytes.Equal(data, got) {
		t.Fatal("parallel original-file download did not preserve every byte")
	}
}
