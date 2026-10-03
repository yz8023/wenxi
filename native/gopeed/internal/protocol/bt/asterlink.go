package bt

import "golang.org/x/time/rate"

// One active BT payload is scheduled at a time. Even during metadata resolution
// storage must point inside AsterLink's cache, never the process working folder.
var asterlinkBaseDir string
var asterlinkDownloadLimit = rate.NewLimiter(rate.Inf, 512*1024)

func SetAsterLinkCache(path string) { asterlinkBaseDir = path }
func SetAsterLinkLimit(bytes int64) {
	if bytes <= 0 {
		asterlinkDownloadLimit.SetLimit(rate.Inf)
	} else {
		asterlinkDownloadLimit.SetLimit(rate.Limit(bytes))
	}
}
