package mobile

import "runtime/debug"

// Network Extension also needs memory for packet flow, the Swift bridge and native buffers.
func init() { debug.SetMemoryLimit(14 << 20) }
