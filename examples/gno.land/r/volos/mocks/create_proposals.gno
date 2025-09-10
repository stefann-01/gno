package mocks

import (
	"std"
	"time"
	"gno.land/r/volos/gov/governance"
	"gno.land/r/volos/gov/vls"
	"gno.land/r/volos/gov/staker"
	"gno.land/r/volos/core"
	u256 "gno.land/p/gnoswap/uint256"
)

// callback function that will be executed if the proposal passes
// This sets the fee to 15% (0.15 * 1e18 = 150000000000000000)
func setFeeCallback() {
	core.SetFee(cross, "gno.land/r/demo/wugnot:gno.land/r/gnoswap/v1/gns:3000:0", 5)
}

func CreateProposals(cur realm) {
	vls.Faucet(cross, 100000000)
	vls.Approve(cross, std.DerivePkgAddr("gno.land/r/volos/gov/staker"), 100000000)
	staker.Stake(cross, 100000, std.DerivePkgAddr("gno.land/r/volos/mocks"))
	// Create proposals with different durations
	// Shortest proposal (1 minute) - will get most YES votes
	governance.CreateProposal(
		cross,
		"Set Fee to 15% - Short Duration", 
		"This proposal sets the market fee to 15% with a short voting period",
		time.Duration(1*time.Minute),
		setFeeCallback,
	)

	// Medium proposal (1 hour) - will get some YES votes
	governance.CreateProposal(
		cross,
		"Set Fee to 15% - Medium Duration", 
		"This proposal sets the market fee to 15% with a medium voting period",
		time.Duration(1*time.Hour),
		setFeeCallback,
	)

	// Longest proposal (5 hours) - will get fewest YES votes
	governance.CreateProposal(
		cross,
		"Set Fee to 15% - Long Duration", 
		"This proposal sets the market fee to 15% with a long voting period",
		time.Duration(5*time.Hour),
		setFeeCallback,
	)
} 
