// Package init's only task is to load the initial GovDAO version into the bridge.
// This is done to avoid gov/dao/v2 as a bridge dependency,
// As this can often lead to cyclic dependency errors.
package init

import (
	"gno.land/r/gov/dao/bridge"
	govdao "gno.land/r/gov/dao/v2"
)

func init() {
	bridge.LoadGovDAO(govdao.GovDAO)
}
