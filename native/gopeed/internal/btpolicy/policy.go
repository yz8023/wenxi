// Package btpolicy shares bounded peer discovery between metadata, downloads,
// and streaming. Peer addresses remain in memory and expire after ten minutes.
package btpolicy

import (
	"net/netip"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
)

const PeerLimit = 80
const peerLifetime = 10 * time.Minute

var publicTrackers = [][]string{
	{"udp://tracker.opentrackr.org:1337/announce"},
	{"udp://open.stealth.si:80/announce"},
	{"udp://tracker.torrent.eu.org:451/announce"},
	{"https://tracker.gbitt.info/announce"},
}

type peerMemo struct {
	peers []torrent.PeerInfo
	until time.Time
}

var cache = struct {
	sync.Mutex
	values map[metainfo.Hash]peerMemo
}{values: make(map[metainfo.Hash]peerMemo)}

func Configure(cfg *torrent.ClientConfig) {
	cfg.EstablishedConnsPerTorrent = PeerLimit
	cfg.HalfOpenConnsPerTorrent = 24
	cfg.TotalHalfOpenConns = 48
	// Keep the library's TCP/uTP, DHT, PEX and encryption negotiation defaults.
	// WebTorrent is a browser transport; native peers and webseeds remain enabled.
	cfg.DisableWebtorrent = true
	cfg.Seed = false
}

func Restore(t *torrent.Torrent) {
	cache.Lock()
	item, ok := cache.values[t.InfoHash()]
	if ok && time.Now().After(item.until) {
		delete(cache.values, t.InfoHash())
		ok = false
	}
	cache.Unlock()
	if ok {
		t.AddPeers(item.peers)
	}
}

func AddPublicTrackers(t *torrent.Torrent) {
	info := t.Info()
	// Metadata must establish that this is public before expanding discovery.
	if info != nil && (info.Private == nil || !*info.Private) {
		t.AddTrackers(publicTrackers)
	}
}

func Remember(t *torrent.Torrent) {
	if t == nil {
		return
	}
	peers := make([]torrent.PeerInfo, 0, PeerLimit)
	seen := map[netip.AddrPort]bool{}
	// The pinned library's KnownSwarm reads pending maps without a lock. Use
	// PeerConns' locked snapshot and immutable outgoing remote addresses instead.
	for _, conn := range t.PeerConns() {
		if conn.Discovery == torrent.PeerSourceIncoming || conn.RemoteAddr == nil {
			continue
		}
		addr, err := netip.ParseAddrPort(conn.RemoteAddr.String())
		if err != nil || addr.Port() == 0 || seen[addr] {
			continue
		}
		seen[addr] = true
		peers = append(peers, torrent.PeerInfo{Addr: addr, Source: torrent.PeerSourceDirect})
		if len(peers) == PeerLimit {
			break
		}
	}
	if len(peers) == 0 {
		return
	}
	now := time.Now()
	cache.Lock()
	defer cache.Unlock()
	for hash, item := range cache.values {
		if !item.until.After(now) {
			delete(cache.values, hash)
		}
	}
	if len(cache.values) >= 32 {
		var oldest metainfo.Hash
		deadline := now.Add(2 * peerLifetime)
		for hash, item := range cache.values {
			if item.until.Before(deadline) {
				oldest, deadline = hash, item.until
			}
		}
		delete(cache.values, oldest)
	}
	cache.values[t.InfoHash()] = peerMemo{peers: peers, until: now.Add(peerLifetime)}
}

func Clear() {
	cache.Lock()
	cache.values = make(map[metainfo.Hash]peerMemo)
	cache.Unlock()
}
