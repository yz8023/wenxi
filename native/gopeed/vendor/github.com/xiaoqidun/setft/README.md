# setft

Golang SetFileTime，修改文件的访问时间、创建时间、修改时间。

# 使用说明

```go
package main

import (
	"github.com/xiaoqidun/setft"
	"log"
	"time"
)

func main() {
	// 时间字符格式
	layout := "2006-01-02 15:04:05"
	// 设置访问时间
	atime, _ := time.ParseInLocation(layout, "2021-01-01 00:00:00", time.Local)
	// 设置创建时间
	ctime, _ := time.ParseInLocation(layout, "2021-01-01 00:00:00", time.Local)
	// 设置修改时间
	mtime, _ := time.ParseInLocation(layout, "2021-01-01 00:00:00", time.Local)
	// 修改文件时间
	if err := setft.SetFileTime("setft_test.go", atime, ctime, mtime); err != nil {
		log.Println(err)
	}
}
```