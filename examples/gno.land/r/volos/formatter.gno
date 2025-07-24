package volos

import (
	"strings"
	"gno.land/p/demo/ufmt"
)

func FormatMoney(amount float64) string {
	s := ufmt.Sprintf("%.2f", amount)
	parts := strings.Split(s, ".")
	intPart := parts[0]
	n := len(intPart)
	if n <= 3 {
		return s
	}
	out := ""
	count := 0
	for i := n - 1; i >= 0; i-- {
		if count > 0 && count%3 == 0 {
			out = "," + out
		}
		out = string(intPart[i]) + out
		count++
	}
	if len(parts) > 1 {
		out = out + "." + parts[1]
	}
	return out
} 
