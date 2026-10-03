package http

import (
	"reflect"
	"sync"
	"testing"
)

func TestReadableIntervalsKeepHolesAndMergeAdjacentWrites(t *testing.T) {
	var r readableBytes
	r.add(24, 32)
	r.add(0, 8)
	r.add(4, 10)
	want := [][2]int64{{0, 10}, {24, 32}}
	if got := r.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("holes lost: %v", got)
	}
	r.add(10, 24)
	if got := r.snapshot(); !reflect.DeepEqual(got, [][2]int64{{0, 32}}) {
		t.Fatalf("adjacent writes not merged: %v", got)
	}
	copy := r.snapshot()
	copy[0][1] = 999
	if r.snapshot()[0][1] != 32 {
		t.Fatal("snapshot aliases live intervals")
	}
}

func TestReadableIntervalsConcurrentPublication(t *testing.T) {
	var r readableBytes
	var group sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		group.Add(1)
		go func(worker int) {
			defer group.Done()
			for index := 0; index < 128; index++ {
				start := int64((worker*128 + index) * 8192)
				r.add(start, start+8192)
				_ = r.snapshot()
			}
		}(worker)
	}
	group.Wait()
	if got := r.snapshot(); !reflect.DeepEqual(got, [][2]int64{{0, 16 * 128 * 8192}}) {
		t.Fatalf("lost completed writes: %v", got)
	}
}
