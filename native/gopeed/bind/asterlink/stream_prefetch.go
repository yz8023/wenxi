package gopeed

import (
	"context"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/anacrolix/torrent"
)

const streamProbeBytes int64 = 2 * 1024 * 1024

func streamRequestBytes(value string, length int64) int64 {
	if !strings.HasPrefix(value, "bytes=") {
		return length
	}
	parts := strings.SplitN(strings.TrimPrefix(value, "bytes="), "-", 2)
	if len(parts) != 2 {
		return length
	}
	end, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return length
	}
	if parts[0] == "" {
		return min(length, max(0, end))
	}
	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 || end < start {
		return length
	}
	if start >= length {
		return 0
	}
	return min(end, length-1) - start + 1
}

func (s *torrentStream) streamReadahead(requestBytes int64) torrent.ReadaheadFunc {
	// These callbacks run under the torrent lock: inspect immutable values and
	// atomics only. Short index probes never inherit a large playback window.
	return func(ctx torrent.ReadaheadContext) int64 {
		if requestBytes <= streamProbeBytes {
			return streamProbeBytes
		}
		window := max(streamProbeBytes, s.readahead.Load())
		read := ctx.CurrentPos - ctx.ContiguousReadStartPos
		if read >= 512*1024 {
			window = max(window, 8*1024*1024, 2*s.pieceLength)
		}
		if read >= 4*1024*1024 {
			window = max(window, 16*1024*1024, 4*s.pieceLength)
		}
		window = min(streamMaxReadahead, window)
		s.readahead.Store(window)
		return window
	}
}

func (s *torrentStream) startContainerProbes() {
	switch strings.ToLower(filepath.Ext(s.name)) {
	case ".mp4", ".mov", ".m4v", ".m4a", ".mkv", ".mka", ".webm", ".avi":
	default:
		return
	}
	if s.file.Length() <= 2*streamProbeBytes {
		return
	}
	s.requestMu.Lock()
	if s.closed || s.probesStarted {
		s.requestMu.Unlock()
		return
	}
	s.probesStarted = true
	ctx, cancel := context.WithTimeout(s.ctx, 45*time.Second)
	s.probeCancel = cancel
	s.requests.Add(1)
	s.requestMu.Unlock()
	go func() {
		defer s.requests.Done()
		defer cancel()
		// MP4/MOV moov and Matroska cues are often at EOF. Fetch the narrow
		// tail window while the demuxer waits for its first verified head piece.
		// This starts only on a real body read, never for HEAD or invalid ranges.
		reader := s.file.NewReader()
		defer reader.Close()
		reader.SetReadahead(streamProbeBytes)
		if _, err := reader.Seek(s.file.Length()-streamProbeBytes, io.SeekStart); err != nil {
			return
		}
		buf := make([]byte, 32*1024)
		remaining := streamProbeBytes
		for remaining > 0 && ctx.Err() == nil {
			n, err := reader.ReadContext(ctx, buf[:min(int64(len(buf)), remaining)])
			remaining -= int64(n)
			if err != nil || n == 0 {
				return
			}
		}
	}()
}
