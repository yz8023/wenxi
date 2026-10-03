package gopeed

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

func prepareStreamFile(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	// A tail/index probe must not zero-fill an entire movie on Windows. Sparse
	// support is optional; unsupported filesystems keep regular-file behavior.
	var returned uint32
	_ = windows.DeviceIoControl(windows.Handle(file.Fd()), windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil)
	return nil
}
