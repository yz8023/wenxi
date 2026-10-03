// AsterLink per-task retry and speed options, 2026-09-12. Gopeed v1.8.1 / GPL-3.0.
package http

type ReqExtra struct {
	Method string            `json:"method"`
	Header map[string]string `json:"header"`
	Body   string            `json:"body"`
}

type OptsExtra struct {
	Connections int `json:"connections"`
	// ConnectionProfile selects the app's per-route range budget.
	ConnectionProfile string `json:"connectionProfile,omitempty"`
	// AsterLink options; nil retains Gopeed's default of three retries.
	RetryLimit *int  `json:"retryLimit,omitempty"`
	SpeedLimit int64 `json:"speedLimit,omitempty"`
	// AutoTorrent when task download complete, and it is a .torrent file, it will be auto create a new task for the torrent file
	AutoTorrent bool `json:"autoTorrent"`
}

// Stats for download
type Stats struct {
	Connections []*StatsConnection `json:"connections"`
}

type StatsConnection struct {
	Downloaded int64 `json:"downloaded"`
	Completed  bool  `json:"completed"`
	Failed     bool  `json:"failed"`
	RetryTimes int   `json:"retryTimes"`
}
