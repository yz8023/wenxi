package controller

import (
	"bytes"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestSparseRangePayloadKeepsLengthAndZeroHoles(t *testing.T) {
	const size = 64 * 1024 * 1024
	f, err := (&DefaultFileController{}).Touch(filepath.Join(t.TempDir(), "ranges.bin"), size)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	data := []byte("last verified range")
	if _, err := f.WriteAt(data, size-int64(len(data))); err != nil {
		t.Fatal(err)
	}
	info, err := f.Stat()
	if err != nil || info.Size() != size {
		t.Fatal("preallocated payload length changed")
	}
	got := make([]byte, len(data))
	if _, err := f.ReadAt(got, size-int64(len(data))); err != nil || !bytes.Equal(got, data) {
		t.Fatal("distant range was not preserved")
	}
	if _, err := f.ReadAt(got, size/2); err != nil || !bytes.Equal(got, make([]byte, len(got))) {
		t.Fatal("unwritten hole did not read as zeros")
	}
	var handleInfo windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(windows.Handle(f.Fd()), &handleInfo); err != nil {
		t.Fatal(err)
	}
	if handleInfo.FileAttributes&windows.FILE_ATTRIBUTE_SPARSE_FILE == 0 {
		t.Log("filesystem declined sparse support; regular-file fallback preserved bytes")
	}
}
