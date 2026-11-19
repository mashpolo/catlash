package mobile

import (
	"encoding/json"
	"runtime"
)

// RuntimeMemoryJSON reports only process-wide Go allocation counters. Native and
// Swift allocations are outside these counters and must be sampled by the host.
func RuntimeMemoryJSON() string {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	data, _ := json.Marshal(map[string]uint64{
		"heapAlloc": stats.HeapAlloc, "heapInuse": stats.HeapInuse,
		"heapIdle": stats.HeapIdle, "heapReleased": stats.HeapReleased,
		"stackInuse": stats.StackInuse, "sys": stats.Sys,
		"runtimeBytes": stats.Sys - stats.HeapReleased,
		"goroutines":   uint64(runtime.NumGoroutine()), "numGC": uint64(stats.NumGC), "nextGC": stats.NextGC,
	})
	return string(data)
}
