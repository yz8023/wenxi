package gopeed

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

func torrentFixture(t *testing.T, size int) (string, []byte) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "fixture")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, size)
	for i := range data {
		data[i] = byte((i*79 + i/117) % 251)
	}
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("not selected\n"), 0600)
	os.WriteFile(filepath.Join(dir, "b.bin"), data, 0600)
	os.WriteFile(filepath.Join(dir, "empty.txt"), nil, 0600)
	info := metainfo.Info{PieceLength: 16 * 1024}
	private := true
	info.Private = &private
	if err := info.BuildFromFilePath(dir); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * time.Millisecond)
		http.FileServer(http.Dir(root)).ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	mi := metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info), UrlList: metainfo.UrlList{server.URL + "/"}}
	var buf bytes.Buffer
	if err := mi.Write(&buf); err != nil {
		t.Fatal(err)
	}
	return torrentPrefix + base64.StdEncoding.EncodeToString(buf.Bytes()), data
}

func beginBT(t *testing.T, id, data string, limit int64) {
	t.Helper()
	beginBTIndex(t, id, data, 1, limit)
}

func beginBTIndex(t *testing.T, id, data string, index int, limit int64) {
	t.Helper()
	input, _ := json.Marshal(request{ID: id, URL: "magnet:?xt=urn:btih:fixture", TorrentData: data, TorrentIndex: index, Connections: 32, Retries: 3, SpeedLimit: limit})
	if err := Begin(string(input)); err != nil {
		t.Fatal(err)
	}
}

func TestTorrentConsecutiveFilesAndZeroLengthUseIndependentStorage(t *testing.T) {
	_, payload, _ := openTestCore(t)
	data, second := torrentFixture(t, 256*1024)
	for index, want := range [][]byte{[]byte("not selected\n"), second, {}} {
		id := "consecutive-" + strconv.Itoa(index)
		beginBTIndex(t, id, data, index, 0)
		state := waitState(t, id, func(s snapshot) bool { return s.Status == "done" })
		assertPayload(t, state, want)
		if err := Remove(id); err != nil {
			t.Fatal(err)
		}
		if err := os.RemoveAll(filepath.Join(payload, id)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTorrentPauseAndResumeRechecksEvictedPayloadWithoutCoreRestart(t *testing.T) {
	_, payload, _ := openTestCore(t)
	data, want := torrentFixture(t, 2*1024*1024)
	beginBT(t, "evicted", data, 512*1024)
	waitState(t, "evicted", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause("evicted"); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(payload, "evicted", "fixture")); err != nil {
		t.Fatal(err)
	}
	// Same process and infohash, different task directory while the first is paused.
	beginBTIndex(t, "other-file", data, 0, 0)
	assertPayload(t, waitState(t, "other-file", func(s snapshot) bool { return s.Status == "done" }), []byte("not selected\n"))
	if err := Remove("other-file"); err != nil {
		t.Fatal(err)
	}
	beginBT(t, "evicted", data, 512*1024)
	assertPayload(t, waitState(t, "evicted", func(s snapshot) bool { return s.Status == "done" }), want)
}

func TestTorrentMagnetMetadataThenPeerDownload(t *testing.T) {
	openTestCore(t)
	root := t.TempDir()
	want := bytes.Repeat([]byte("AsterLink local BT peer fixture\n"), 8192)
	path := filepath.Join(root, "peer.bin")
	if err := os.WriteFile(path, want, 0600); err != nil {
		t.Fatal(err)
	}
	private := true
	info := metainfo.Info{PieceLength: 16 * 1024, Private: &private}
	if err := info.BuildFromFilePath(path); err != nil {
		t.Fatal(err)
	}
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir, cfg.ListenPort = root, 0
	cfg.ListenHost = func(string) string { return "127.0.0.1" }
	cfg.DisableIPv6, cfg.DisableUTP, cfg.NoDHT, cfg.Seed = true, true, true, true
	seedStorage := storage.NewFileWithCompletion(root, storage.NewMapPieceCompletion())
	defer seedStorage.Close()
	cfg.DefaultStorage = seedStorage
	seed, err := torrent.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer seed.Close()
	_, portString, err := net.SplitHostPort(seed.ListenAddrs()[0].String())
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portString)
	peer := []byte{127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(peer[4:], uint16(port))
	tracker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(bencode.MustMarshal(map[string]any{"interval": 1, "peers": string(peer)}))
	}))
	defer tracker.Close()
	mi := metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info), Announce: tracker.URL}
	tor, err := seed.AddTorrent(&mi)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for tor.BytesCompleted() != int64(len(want)) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if tor.BytesCompleted() != int64(len(want)) {
		t.Fatal("local seeder failed verification")
	}
	magnet := "magnet:?xt=urn:btih:" + mi.HashInfoBytes().String() + "&tr=" + url.QueryEscape(tracker.URL)
	input, _ := json.Marshal(map[string]string{"id": "peer-metadata", "url": magnet})
	if err := ResolveTorrent(string(input)); err != nil {
		t.Fatal(err)
	}
	defer CancelTorrent("peer-metadata")
	var result metadataState
	deadline = time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := TorrentMetadata("peer-metadata")
		if err != nil {
			t.Fatal(err)
		}
		json.Unmarshal([]byte(raw), &result)
		if result.Status == "error" {
			torrentMu.Lock()
			cause := metadataJobs["peer-metadata"].cause
			torrentMu.Unlock()
			t.Fatalf("%s: %v", result.Error, cause)
		}
		if result.Status == "ready" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if result.Info == nil {
		t.Fatal("magnet did not resolve from the local peer")
	}
	stats := tor.Stats()
	if stats.BytesWrittenData.Int64() != 0 {
		t.Fatal("metadata resolution downloaded payload before selection")
	}
	CancelTorrent("peer-metadata")
	// Metadata discovery remembers a working peer. Neither the stream nor the
	// following download should need another successful tracker announce.
	tracker.Close()
	mi.Announce, mi.AnnounceList = "", nil
	var warm bytes.Buffer
	if err := mi.Write(&warm); err != nil {
		t.Fatal(err)
	}
	result.Info.Data = torrentPrefix + base64.StdEncoding.EncodeToString(warm.Bytes())
	streamURL := startStreamForTest(t, "peer-stream", result.Info.Data, 0)
	response, streamed := readStreamRange(t, streamURL, "bytes=100-65635")
	if response.StatusCode != http.StatusPartialContent || !bytes.Equal(streamed, want[100:65636]) {
		t.Fatal("warm peer did not serve verified streaming bytes")
	}
	StopTorrentStream("peer-stream")
	beginBTIndex(t, "peer-download", result.Info.Data, 0, 0)
	assertPayload(t, waitState(t, "peer-download", func(s snapshot) bool { return s.Status == "done" }), want)
	if err := Remove("peer-download"); err != nil {
		t.Fatal(err)
	}
}

func TestTorrentLocalMetadataAndCancel(t *testing.T) {
	openTestCore(t)
	data, _ := torrentFixture(t, 64*1024)
	input, _ := json.Marshal(map[string]string{"id": "metadata", "url": data})
	if err := ResolveTorrent(string(input)); err != nil {
		t.Fatal(err)
	}
	defer CancelTorrent("metadata")
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := TorrentMetadata("metadata")
		if err != nil {
			t.Fatal(err)
		}
		var state metadataState
		json.Unmarshal([]byte(raw), &state)
		if state.Status == "error" {
			t.Fatal(state.Error)
		}
		if state.Status == "ready" {
			if len(state.Info.Files) != 3 || state.Info.Files[1].Path != "fixture/b.bin" || state.Info.Files[1].Size != 64*1024 {
				t.Fatalf("bad metadata: %+v", state.Info)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("metadata timed out")
}

func TestTorrentSelectedFileVerifiedAndDeleted(t *testing.T) {
	_, payload, _ := openTestCore(t)
	data, want := torrentFixture(t, 512*1024)
	beginBT(t, "bt-selected", data, 0)
	state := waitState(t, "bt-selected", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, want)
	if state.Total != int64(len(want)) || !strings.HasPrefix(state.Path, filepath.Join(payload, "bt-selected")+string(os.PathSeparator)) {
		t.Fatalf("invalid selected payload: %+v", state)
	}
	if err := Remove("bt-selected"); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(state.Path, state.Path+".export"); err != nil {
		t.Fatal("torrent did not release file:", err)
	}
}

func TestTorrentPausedStateResumesAndRechecks(t *testing.T) {
	storage, payload, key := openTestCore(t)
	data, want := torrentFixture(t, 2*1024*1024)
	beginBT(t, "bt-resume", data, 512*1024)
	waitState(t, "bt-resume", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause("bt-resume"); err != nil {
		t.Fatal(err)
	}
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	beginBT(t, "bt-resume", data, 512*1024)
	state := waitState(t, "bt-resume", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, want)
	if err := Remove("bt-resume"); err != nil {
		t.Fatal(err)
	}
}

func TestTorrentUnreachableMagnetCancelsWithoutBlockingHTTP(t *testing.T) {
	openTestCore(t)
	input, _ := json.Marshal(map[string]string{"id": "cancel-magnet", "url": "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"})
	if err := ResolveTorrent(string(input)); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	CancelTorrent("cancel-magnet")
	if time.Since(start) > time.Second {
		t.Fatal("cancel blocked")
	}
	if _, err := TorrentMetadata("cancel-magnet"); err == nil {
		t.Fatal("cancelled metadata remained visible")
	}
	f := serveFile(t, 65536, 0)
	startFile(t, "http-after-bt-cancel", f.server.URL+"/file", 4, 0)
	assertPayload(t, waitState(t, "http-after-bt-cancel", func(s snapshot) bool { return s.Status == "done" }), f.data)
}

func TestTorrentRejectsUnsafePathsAndInvalidSelection(t *testing.T) {
	openTestCore(t)
	data, _ := torrentFixture(t, 65536)
	mi, _, err := parseTorrent(data)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := mi.UnmarshalInfo()
	info.Name = ".."
	mi.InfoBytes = bencode.MustMarshal(info)
	var buffer bytes.Buffer
	mi.Write(&buffer)
	if _, _, err := parseTorrent(torrentPrefix + base64.StdEncoding.EncodeToString(buffer.Bytes())); err == nil {
		t.Fatal("unsafe path accepted")
	}
	input, _ := json.Marshal(request{ID: "bad-index", TorrentData: data, TorrentIndex: 100, Connections: 32})
	if Begin(string(input)) == nil {
		t.Fatal("invalid selection accepted")
	}
}
