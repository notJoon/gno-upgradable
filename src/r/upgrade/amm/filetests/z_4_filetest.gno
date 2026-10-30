// PKGPATH: gno.land/r/demo/main

// A migration cannot leave a token allowance behind after it returns.
package main

import (
	"chain"
	"testing"

	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/amm"
	v1 "gno.land/r/upgrade/amm/v1"
	"gno.land/r/upgrade/testtoken"
)

type next struct{ v1.Impl }


func (next) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {
	c.ApproveForCall(testtoken.A, chain.PackageAddress("gno.land/r/demo/main"), 100)
}

func main(cur realm) {
	pool := chain.PackageAddress("gno.land/r/upgrade/amm")
	self := chain.PackageAddress("gno.land/r/demo/main")
	testing.SetRealm(testing.NewUserRealm(amm.Admin0))
	amm.Approve(cross(cur), "gno.land/r/upgrade/amm/v1")
	v1.Upgrade(cross(cur))

	amm.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	amm.Upgrade(cross(cur), next{})
	testing.SkipHeights(amm.UpgradeDelay)
	amm.Upgrade(cross(cur), next{})
	println("allowance after migration:", testtoken.A.Allowance(pool, self))
}

// Output:
// allowance after migration: 0
