package timecheck

import (
	"std"
	"time"
)

// RecordTime captures the current time and block height
func RecordTime(cur realm) {
	Timestamp := time.Now().Unix()
	Height := std.ChainHeight()
	print(">>> Block Height: ", Height, ", Block Timestamp: ", Timestamp, " <<<")
}