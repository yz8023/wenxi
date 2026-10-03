// +build !windows

package setft

import (
	"os"
	"time"
)

func SetFileTime(path string, atime, ctime, mtime time.Time) (err error) {
	return os.Chtimes(path, atime, mtime)
}
