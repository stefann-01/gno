package timecheck

import (
	"std"
	"time"
)

// Global counter that tracks the number of RecordTime calls
var callCounter int

func RecordTime(cur realm) {
	callCounter++
	Timestamp := time.Now().Unix()
	Height := std.ChainHeight()
	print(">>> Block Height: ", Height, ", Block Timestamp: ", Timestamp, ", Call Count: ", callCounter, " <<<")
}