package gopeed

import (
	"bytes"
	"os"
	"testing"
	"time"
)

func TestReadableRangesProvePayloadBytesAndSurviveReopen(t *testing.T) {
	storage, cache, key := openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	startFile(t, "readable", f.server.URL+"/file", 4, 128*1024)
	state := waitState(t, "readable", func(s snapshot) bool {
		return len(s.ReadableRanges) > 0 && s.Downloaded > 0 && s.Status != "done"
	})
	if err := Pause("readable"); err != nil {
		t.Fatal(err)
	}
	state = waitState(t, "readable", func(s snapshot) bool { return s.Status == "pause" })
	var count int64
	file, err := os.Open(state.Path)
	if err != nil {
		t.Fatal(err)
	}
	for _, span := range state.ReadableRanges {
		data := make([]byte, span[1]-span[0])
		if _, err := file.ReadAt(data, span[0]); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(data, f.data[span[0]:span[1]]) {
			t.Fatalf("unwritten range published: %v", span)
		}
		count += span[1] - span[0]
	}
	file.Close()
	if count <= 0 || count >= state.Total || count != state.Downloaded {
		t.Fatalf("preallocation confused with completed bytes: %d vs %+v", count, state)
	}
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	if err := Open(storage, cache, key); err != nil {
		t.Fatal(err)
	}
	startFile(t, "readable", f.server.URL+"/file", 4, 128*1024)
	restored := waitState(t, "readable", func(s snapshot) bool { return len(s.ReadableRanges) > 0 })
	var restoredCount int64
	for _, span := range restored.ReadableRanges {
		restoredCount += span[1] - span[0]
	}
	if restoredCount < count {
		t.Fatalf("checkpoint lost readable intervals: %+v", restored)
	}
	assertPayload(t, waitState(t, "readable", func(s snapshot) bool { return s.Status == "done" }, 30*time.Second), f.data)
}
