package main

import (
    core "gno.land/r/volos/core"
     u256 "gno.land/p/gnoswap/uint256"
)

func main() {
    core.SetFee(cross,"gno.land/r/demo/wugnot:gno.land/r/gnoswap/v1/gns:3000:0", u256.NewUint(300000000000000000)) 
}
