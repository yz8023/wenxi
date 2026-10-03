package gopeed

import (
	"context"
	"io"
	"sync"

	"github.com/anacrolix/generics"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

// The pinned torrent client can finish an already received chunk after Close.
// Serialize cache deletion against I/O and discard those late writes only for
// ephemeral playback storage, after its HTTP readers and peer session close.
// Download storage uses its existing durable implementation.
type streamStorage struct {
	base   storage.ClientImplCloser
	mu     sync.RWMutex
	closed bool
}

func (s *streamStorage) OpenTorrent(ctx context.Context, info *metainfo.Info, hash metainfo.Hash) (storage.TorrentImpl, error) {
	impl, err := s.base.OpenTorrent(ctx, info, hash)
	if err != nil {
		return impl, err
	}
	if piece := impl.Piece; piece != nil {
		impl.Piece = func(p metainfo.Piece) storage.PieceImpl {
			return &streamPiece{piece(p), s}
		}
	}
	if piece := impl.PieceWithHash; piece != nil {
		impl.PieceWithHash = func(p metainfo.Piece, hash generics.Option[[]byte]) storage.PieceImpl {
			return &streamPiece{piece(p, hash), s}
		}
	}
	if flush := impl.Flush; flush != nil {
		impl.Flush = func() error {
			s.mu.RLock()
			defer s.mu.RUnlock()
			if s.closed {
				return nil
			}
			return flush()
		}
	}
	close := impl.Close
	impl.Close = func() error {
		s.freeze()
		if close != nil {
			return close()
		}
		return nil
	}
	return impl, nil
}

func (s *streamStorage) freeze() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
}

func (s *streamStorage) Close() error {
	s.freeze()
	return s.base.Close()
}

type streamPiece struct {
	base storage.PieceImpl
	s    *streamStorage
}

func (p *streamPiece) WriteAt(data []byte, offset int64) (int, error) {
	p.s.mu.RLock()
	defer p.s.mu.RUnlock()
	if p.s.closed {
		return len(data), nil
	}
	return p.base.WriteAt(data, offset)
}

func (p *streamPiece) ReadAt(data []byte, offset int64) (int, error) {
	p.s.mu.RLock()
	defer p.s.mu.RUnlock()
	if p.s.closed {
		return 0, io.EOF
	}
	return p.base.ReadAt(data, offset)
}

func (p *streamPiece) MarkComplete() error {
	p.s.mu.RLock()
	defer p.s.mu.RUnlock()
	if p.s.closed {
		return nil
	}
	return p.base.MarkComplete()
}

func (p *streamPiece) MarkNotComplete() error {
	p.s.mu.RLock()
	defer p.s.mu.RUnlock()
	if p.s.closed {
		return nil
	}
	return p.base.MarkNotComplete()
}

func (p *streamPiece) Completion() storage.Completion {
	p.s.mu.RLock()
	defer p.s.mu.RUnlock()
	if p.s.closed {
		return storage.Completion{Ok: true}
	}
	return p.base.Completion()
}
