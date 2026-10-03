package http

import "sync"

// Half-open intervals are published only after WriteAt succeeds. File length
// cannot prove readability because HTTP downloads preallocate their payload.
type readableBytes struct {
	mu          sync.RWMutex
	initialized bool
	ranges      [][2]int64
}

func (r *readableBytes) add(start, end int64) {
	if start < 0 || end <= start {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.addLocked(start, end)
}

func (r *readableBytes) addLocked(start, end int64) {
	first := 0
	for first < len(r.ranges) && r.ranges[first][1] < start {
		first++
	}
	last := first
	for last < len(r.ranges) && r.ranges[last][0] <= end {
		start = min(start, r.ranges[last][0])
		end = max(end, r.ranges[last][1])
		last++
	}
	if first == last {
		r.ranges = append(r.ranges, [2]int64{})
		copy(r.ranges[first+1:], r.ranges[first:])
	} else {
		copy(r.ranges[first+1:], r.ranges[last:])
		r.ranges = r.ranges[:len(r.ranges)-(last-first)+1]
	}
	r.ranges[first] = [2]int64{start, end}
}

func (r *readableBytes) snapshot() [][2]int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return append([][2]int64{}, r.ranges...)
}

func (f *Fetcher) initializeReadable() {
	f.readable.mu.Lock()
	defer f.readable.mu.Unlock()
	if !f.meta.Res.Range {
		// Non-range retries truncate the file. Never expose a partial prefix
		// from those transfers while it may be replaced under a reader.
		f.readable.ranges = nil
		f.readable.initialized = true
		return
	}
	if f.readable.initialized {
		return
	}
	f.readable.initialized = true
	for _, conn := range f.connections {
		if conn.Chunk != nil && conn.Chunk.Downloaded > 0 {
			start := conn.Chunk.Begin
			end := min(start+conn.Chunk.Downloaded, min(conn.Chunk.End+1, f.meta.Res.Size))
			if start >= 0 && end > start {
				f.readable.addLocked(start, end)
			}
		}
	}
}

func (f *Fetcher) ReadableRanges() [][2]int64 {
	return f.readable.snapshot()
}
