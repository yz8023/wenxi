package http

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestMisleadingOneByteProbeStillDownloadsCompleteFile(t *testing.T) {
	data := bytes.Repeat([]byte("range-probe-original-content\n"), 64*1024)
	var retried atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") == "bytes=0-0" {
			w.Header().Set("Content-Length", "1")
			_, _ = w.Write(data[:1])
			return
		}
		var first, last int
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= len(data) {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first == 0 && last == 1 {
			retried.Store(true)
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
	if f.Meta().Res.Size != int64(len(data)) || !f.Meta().Res.Range || !retried.Load() {
		t.Fatalf("misleading single-byte probe was accepted: size=%d, range=%v, retry=%v", f.Meta().Res.Size, f.Meta().Res.Range, retried.Load())
	}
	if err := f.Create(&base.Options{Name: "original.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 4}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	if err := f.Wait(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || !bytes.Equal(data, got) {
		t.Fatal("compatibility probing did not preserve the complete original file")
	}
}

func TestOneByteFileRemainsDownloadableAfterProbeRetry(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1")
		_, _ = w.Write([]byte{42})
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if f.Meta().Res.Size != 1 {
		t.Fatalf("one-byte file size changed to %d", f.Meta().Res.Size)
	}
	if err := f.Create(&base.Options{Name: "one.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 4}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	if err := f.Wait(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || !bytes.Equal(got, []byte{42}) {
		t.Fatal("one-byte file did not download unchanged")
	}
}
