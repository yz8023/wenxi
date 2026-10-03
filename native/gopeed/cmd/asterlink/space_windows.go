package main

import (
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
)

func availableSpace(path string) (uint64, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	for {
		if _, err := os.Stat(absolute); err == nil {
			break
		}
		parent := filepath.Dir(absolute)
		if parent == absolute {
			return 0, os.ErrNotExist
		}
		absolute = parent
	}
	pointer, err := windows.UTF16PtrFromString(absolute)
	if err != nil {
		return 0, err
	}
	var available, total, free uint64
	err = windows.GetDiskFreeSpaceEx(pointer, &available, &total, &free)
	return available, err
}
