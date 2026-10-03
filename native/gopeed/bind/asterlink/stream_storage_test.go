package gopeed

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

// Hold a real filesystem flush at the I/O boundary to reproduce cleanup
// racing a completed piece's delayed flush, without depending on disk speed.
type heldFlushStorage struct {
	storage.ClientImplCloser
	entered, resume chan struct{}
}

func (s *heldFlushStorage) OpenTorrent(ctx context.Context, info *metainfo.Info, hash metainfo.Hash) (storage.TorrentImpl, error) {
	impl, err := s.ClientImplCloser.OpenTorrent(ctx, info, hash)
	if err != nil {
		return impl, err
	}
	flush := impl.Flush
	impl.Flush = func() error {
		close(s.entered)
		<-s.resume
		return flush()
	}
	return impl, nil
}

func TestTorrentStreamStorageCloseDrainsIOAndPreventsLateRecreation(t *testing.T) {
	root := t.TempDir()
	base := &heldFlushStorage{
		ClientImplCloser: storage.NewFileWithCompletion(root, storage.NewMapPieceCompletion()),
		entered:          make(chan struct{}), resume: make(chan struct{}),
	}
	s := &streamStorage{base: base}
	info := &metainfo.Info{Name: "video.bin", Length: 16, PieceLength: 16, Pieces: make([]byte, 20)}
	impl, err := s.OpenTorrent(context.Background(), info, metainfo.Hash{})
	if err != nil {
		t.Fatal(err)
	}
	piece := impl.Piece(info.Piece(0))
	if _, err = piece.WriteAt([]byte("verified-content"), 0); err != nil {
		t.Fatal(err)
	}
	flushed := make(chan error, 1)
	go func() { flushed <- impl.Flush() }()
	select {
	case <-base.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("flush did not start")
	}
	closed := make(chan error, 1)
	go func() { closed <- s.Close() }()
	select {
	case <-closed:
		close(base.resume)
		t.Fatal("cache close returned while filesystem I/O was active")
	case <-time.After(30 * time.Millisecond):
	}
	close(base.resume)
	for _, done := range []chan error{flushed, closed} {
		select {
		case err = <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("cache close did not drain completed filesystem I/O")
		}
	}
	path := filepath.Join(root, info.Name)
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = impl.Flush(); err != nil {
		t.Fatal(err)
	}
	if _, err = piece.WriteAt([]byte("late"), 0); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("late flush/write recreated deleted playback data")
	}
	if n, err := piece.ReadAt(make([]byte, 16), 0); n != 0 || err != io.EOF {
		t.Fatal("closed playback storage remained readable")
	}
	if piece.Completion().Complete {
		t.Fatal("closed playback storage reported verified data")
	}
}
