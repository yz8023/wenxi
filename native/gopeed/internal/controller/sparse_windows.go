package controller

import (
	"os"

	"golang.org/x/sys/windows"
)

// NTFS otherwise zero-fills a potentially huge prefix on the first WriteAt
// to a distant range. Sparse holes read as zero without blocking other ranges.
// Filesystems without sparse support keep the existing regular-file behavior.
func prepareSparseFile(file *os.File) {
	var returned uint32
	_ = windows.DeviceIoControl(windows.Handle(file.Fd()), windows.FSCTL_SET_SPARSE,
		nil, 0, nil, 0, &returned, nil)
}
