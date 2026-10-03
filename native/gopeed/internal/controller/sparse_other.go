//go:build !windows

package controller

import "os"

func prepareSparseFile(*os.File) {}
