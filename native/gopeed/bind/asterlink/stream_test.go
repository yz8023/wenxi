package gopeed

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
)

func startStreamForTest(t *testing.T, id, data string, index int) string {
	t.Helper()
	request, _ := json.Marshal(map[string]any{"id": id, "torrentData": data, "torrentIndex": index})
	raw, err := StartTorrentStream(string(request))
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal([]byte(raw), &result); err != nil || result.URL == "" {
		t.Fatalf("stream start response: %s, %v", raw, err)
	}
	t.Cleanup(func() { StopTorrentStream(id) })
	return result.URL
}

func readStreamRange(t *testing.T, uri, value string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, uri, nil)
	req.Header.Set("Range", value)
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, data
}

func TestTorrentStreamRangesAndBoundedPrefetch(t *testing.T) {
	_, root, _ := openTestCore(t)
	data, want := torrentFixture(t, 24*1024*1024)
	uri := startStreamForTest(t, "stream-ranges", data, 1)
	client := &http.Client{Timeout: 3 * time.Second}
	head, err := client.Head(uri)
	if err != nil {
		t.Fatal(err)
	}
	head.Body.Close()
	if head.StatusCode != http.StatusOK || head.ContentLength != int64(len(want)) {
		t.Fatalf("HEAD: %d, %d", head.StatusCode, head.ContentLength)
	}
	streamMu.Lock()
	before := streams["stream-ranges"].file.BytesCompleted()
	streamMu.Unlock()
	if before != 0 {
		t.Fatal("metadata/HEAD fetched payload before playback")
	}
	resp, got := readStreamRange(t, uri, "bytes=0-65535")
	if resp.StatusCode != http.StatusPartialContent || !bytes.Equal(got, want[:65536]) ||
		resp.Header.Get("Content-Range") != fmt.Sprintf("bytes 0-65535/%d", len(want)) {
		t.Fatal("initial range returned incorrect file bytes")
	}
	time.Sleep(100 * time.Millisecond)
	streamMu.Lock()
	completed := streams["stream-ranges"].file.BytesCompleted()
	streamMu.Unlock()
	if completed < 65536 || completed > 4*1024*1024 {
		t.Fatalf("small read overfetched the file: %d", completed)
	}
	resp, got = readStreamRange(t, uri, "bytes=-32768")
	if resp.StatusCode != http.StatusPartialContent || !bytes.Equal(got, want[len(want)-32768:]) {
		t.Fatal("tail seek returned incorrect file bytes")
	}
	resp, got = readStreamRange(t, uri, "bytes=7000000-7032767")
	if resp.StatusCode != http.StatusPartialContent || !bytes.Equal(got, want[7000000:7032768]) {
		t.Fatal("middle seek returned incorrect file bytes")
	}
	resp, _ = readStreamRange(t, uri, "bytes=999999999-")
	if resp.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		t.Fatal("out of bounds range was accepted")
	}
	resp, _ = readStreamRange(t, uri, "bytes=0-1,4-5")
	if resp.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		t.Fatal("multipart requests should be bounded to a single range")
	}
	resp, err = client.Get(uri + "-wrong-token")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatal("unexpected path exposed torrent content")
	}
	StopTorrentStream("stream-ranges")
	entries, err := os.ReadDir(filepath.Join(root, streamCacheName))
	if err != nil || len(entries) != 0 {
		t.Fatalf("playback cache not removed: %v %v", entries, err)
	}
	if _, err := client.Get(uri); err == nil {
		t.Fatal("playback listener remained open after stop")
	}
}

func TestTorrentStreamInterruptAndStopCancelMissingPeers(t *testing.T) {
	openTestCore(t)
	data, _ := torrentFixture(t, 256*1024)
	mi, _, err := parseTorrent(data)
	if err != nil {
		t.Fatal(err)
	}
	mi.UrlList = nil
	var encoded bytes.Buffer
	mi.Write(&encoded)
	data = torrentPrefix + base64.StdEncoding.EncodeToString(encoded.Bytes())
	uri := startStreamForTest(t, "stream-cancel", data, 1)
	readDone := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			client := &http.Client{Timeout: 5 * time.Second}
			response, err := client.Get(uri)
			if err == nil {
				_, err = io.Copy(io.Discard, response.Body)
				response.Body.Close()
			}
			readDone <- err
		}()
	}
	deadline := time.Now().Add(2 * time.Second)
	active := false
	for time.Now().Before(deadline) {
		streamMu.Lock()
		s := streams["stream-cancel"]
		s.requestMu.Lock()
		active = len(s.activeReaders) == 2
		s.requestMu.Unlock()
		streamMu.Unlock()
		if active {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !active {
		t.Fatal("media reader did not start")
	}
	InterruptTorrentStream("stream-cancel")
	for i := 0; i < 2; i++ {
		select {
		case <-readDone:
		case <-time.After(2 * time.Second):
			t.Fatal("interrupt left a reader waiting for an unavailable swarm")
		}
	}
	if _, err := TorrentStreamStatus("stream-cancel"); err != nil {
		t.Fatal("decoder retry lost its stream session")
	}
	started := time.Now()
	StopTorrentStream("stream-cancel")
	if time.Since(started) > 2*time.Second {
		t.Fatal("stop waited for a missing peer")
	}
	if _, err := TorrentStreamStatus("stream-cancel"); err == nil {
		t.Fatal("closed stream remained active")
	}
}

func TestTorrentStreamConcurrentRangesDoNotCancelEachOther(t *testing.T) {
	openTestCore(t)
	data, want := torrentFixture(t, 12*1024*1024)
	mi, _, _ := parseTorrent(data)
	webseeds := mi.UrlList
	mi.UrlList = nil
	var encoded bytes.Buffer
	mi.Write(&encoded)
	uri := startStreamForTest(t, "concurrent-ranges", torrentPrefix+base64.StdEncoding.EncodeToString(encoded.Bytes()), 1)
	streamMu.Lock()
	s := streams["concurrent-ranges"]
	streamMu.Unlock()
	type result struct {
		start int
		body  []byte
		err   error
	}
	done := make(chan result, 2)
	for _, start := range []int{0, len(want) - 65536} {
		go func(start int) {
			req, _ := http.NewRequest(http.MethodGet, uri, nil)
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, start+65535))
			res, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
			var body []byte
			if err == nil {
				body, err = io.ReadAll(res.Body)
				res.Body.Close()
			}
			done <- result{start, body, err}
		}(start)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		s.requestMu.Lock()
		active := len(s.activeReaders)
		s.requestMu.Unlock()
		if active == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("both range readers did not remain active")
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case <-done:
		t.Fatal("a parallel index probe cancelled the other missing-piece read")
	case <-time.After(50 * time.Millisecond):
	}
	s.torrent.AddWebSeeds(webseeds)
	for i := 0; i < 2; i++ {
		r := <-done
		if r.err != nil || !bytes.Equal(r.body, want[r.start:r.start+65536]) {
			t.Fatalf("parallel range was truncated: %d bytes, %v", len(r.body), r.err)
		}
	}
}

func TestTorrentStreamLargePiecesPrioritizeTailBeforeHeaderCompletes(t *testing.T) {
	openTestCore(t)
	root := t.TempDir()
	const pieceLength = 8 * 1024 * 1024
	want := make([]byte, 4*pieceLength)
	for i := range want {
		want[i] = byte((i*17 + i/8191) % 251)
	}
	file := filepath.Join(root, "movie.mp4")
	if err := os.WriteFile(file, want, 0600); err != nil {
		t.Fatal(err)
	}
	private := true
	info := metainfo.Info{PieceLength: pieceLength, Private: &private}
	if err := info.BuildFromFilePath(file); err != nil {
		t.Fatal(err)
	}
	headGate := make(chan struct{})
	defer func() {
		select {
		case <-headGate:
		default:
			close(headGate)
		}
	}()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var start int64
		fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &start)
		if start == 0 && r.Method == http.MethodGet {
			select {
			case <-headGate:
			case <-r.Context().Done():
				return
			}
		}
		http.FileServer(http.Dir(root)).ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	mi := metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info), UrlList: metainfo.UrlList{server.URL + "/"}}
	var encoded bytes.Buffer
	mi.Write(&encoded)
	uri := startStreamForTest(t, "large-piece-index", torrentPrefix+base64.StdEncoding.EncodeToString(encoded.Bytes()), 0)
	done := make(chan []byte, 1)
	go func() {
		req, _ := http.NewRequest(http.MethodGet, uri, nil)
		req.Header.Set("Range", "bytes=0-65535")
		response, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
		if err != nil {
			done <- nil
			return
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		done <- body
	}()
	streamMu.Lock()
	s := streams["large-piece-index"]
	streamMu.Unlock()
	deadline := time.Now().Add(3 * time.Second)
	for s.torrent.PieceState(3).Priority < torrent.PiecePriorityReadahead {
		if time.Now().After(deadline) {
			t.Fatal("tail metadata was not prioritized while the head piece was blocked")
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case <-done:
		t.Fatal("head bytes escaped before the complete piece could be verified")
	default:
	}
	close(headGate)
	if got := <-done; !bytes.Equal(got, want[:65536]) {
		t.Fatal("verified initial bytes differ")
	}
	_, tail := readStreamRange(t, uri, "bytes=-65536")
	if !bytes.Equal(tail, want[len(want)-65536:]) {
		t.Fatal("prefetched index bytes differ")
	}
	streamMu.Lock()
	completed := streams["large-piece-index"].file.BytesCompleted()
	streamMu.Unlock()
	if completed > 2*pieceLength {
		t.Fatalf("metadata probes fetched unrelated middle pieces: %d", completed)
	}
}

func TestTorrentStreamReadaheadKeepsProbesSmallAndLargePiecesFlowing(t *testing.T) {
	s := &torrentStream{pieceLength: 8 * 1024 * 1024}
	play := s.streamReadahead(1024 * 1024 * 1024)
	if initial := play(torrent.ReadaheadContext{}); initial > streamProbeBytes {
		t.Fatal("initial format probe opened a full playback window")
	}
	if sustained := play(torrent.ReadaheadContext{CurrentPos: 5 * 1024 * 1024}); sustained < 3*s.pieceLength || sustained > streamMaxReadahead {
		t.Fatalf("large-piece playback window: %d", sustained)
	}
	if next := s.streamReadahead(1024 * 1024 * 1024)(torrent.ReadaheadContext{}); next < 3*s.pieceLength {
		t.Fatal("a new media range forgot the established playback window")
	}
	if probe := s.streamReadahead(65536)(torrent.ReadaheadContext{}); probe > streamProbeBytes {
		t.Fatal("an index probe inherited the sustained playback window")
	}
}

func TestTorrentStreamValidationAndCoreClose(t *testing.T) {
	_, root, _ := openTestCore(t)
	data, _ := torrentFixture(t, 64*1024)
	for _, input := range []map[string]any{
		{"id": "../outside", "torrentData": data, "torrentIndex": 1},
		{"id": "empty", "torrentData": data, "torrentIndex": 2},
		{"id": "bad-index", "torrentData": data, "torrentIndex": -1},
		{"id": "bad-data", "torrentData": "bad", "torrentIndex": 1},
	} {
		raw, _ := json.Marshal(input)
		if _, err := StartTorrentStream(string(raw)); err == nil {
			t.Fatal("invalid stream request accepted")
		}
	}
	outside := t.TempDir()
	keep := filepath.Join(outside, "keep.txt")
	os.WriteFile(keep, []byte("keep"), 0600)
	if clearStreamDirectory(outside, filepath.Join(root, streamCacheName)) == nil {
		t.Fatal("out of scope cache deletion accepted")
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatal("out of scope file changed")
	}
	uri := startStreamForTest(t, "core-close", data, 1)
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: time.Second}
	if response, err := client.Get(uri); err == nil {
		response.Body.Close()
		t.Fatal("core close left stream listener alive")
	}
}
