package setft

import (
	"syscall"
	"time"
)

func SetFileTime(path string, atime, ctime, mtime time.Time) (err error) {
	path, err = syscall.FullPath(path)
	if err != nil {
		return
	}
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	handle, err := syscall.CreateFile(pathPtr, syscall.FILE_WRITE_ATTRIBUTES, syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return
	}
	defer syscall.Close(handle)
	a := syscall.NsecToFiletime(syscall.TimespecToNsec(syscall.NsecToTimespec(atime.UnixNano())))
	c := syscall.NsecToFiletime(syscall.TimespecToNsec(syscall.NsecToTimespec(ctime.UnixNano())))
	m := syscall.NsecToFiletime(syscall.TimespecToNsec(syscall.NsecToTimespec(mtime.UnixNano())))
	return syscall.SetFileTime(handle, &c, &a, &m)
}
