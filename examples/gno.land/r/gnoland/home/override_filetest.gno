package main

import (
	"std"

	"gno.land/p/demo/testutils"
	"gno.land/r/gnoland/home"
)

func main() {
	var admin = std.Address("g1manfred47kzduec920z88wfr64ylksmdcedlf5")
	std.TestSetOriginCaller(admin)
	home.AdminSetOverride("Hello World!")
	println("---")
	println(home.Render(""))
	home.Admin.TransferOwnership(testutils.TestAddress("newAdmin"))
	defer func() {
		r := recover()
		println("r: ", r)
	}()
	home.AdminSetOverride("Not admin anymore")
}

// Output:
// ---
// Hello World!
// r:  ownable: caller is not owner
