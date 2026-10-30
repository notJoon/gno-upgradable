// PKGPATH: gno.land/r/demo/main

// An approved implementation cannot install from a swap callback while the
// old implementation is still updating the pool.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/amm"
	v1 "gno.land/r/upgrade/amm/v1"
	"gno.land/r/upgrade/testtoken"
)

type next struct{ v1.Impl }

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	pool := chain.PackageAddress("gno.land/r/upgrade/amm")
	self := chain.PackageAddress("gno.land/r/demo/main")
	testing.SetRealm(testing.NewUserRealm(amm.Admin0))
	amm.Approve(cross(cur), "gno.land/r/upgrade/amm/v1")
	v1.Upgrade(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	testtoken.Faucet(cross(cur), 1000)
	testtoken.Approve(cross(cur), "A", pool, 1000)
	testtoken.Approve(cross(cur), "B", pool, 1000)
	amm.Call(cross(cur), "AddLiquidity", "1000 1000")

	testing.SetRealm(testing.NewUserRealm(amm.Admin0))
	amm.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	amm.Upgrade(cross(cur), next{})
	testing.SkipHeights(amm.UpgradeDelay)

	activate := func(cur realm, _ int64, _ *amm.CallbackMarker) {
		amm.Upgrade(cross(cur), next{})
	}
	println(revive(func() { amm.Swap(cross(cur), true, 100, 1, self, activate) }))
	println("impl:", amm.ImplPath())
}

// Output:
// upgrade: reentrant call
// impl: gno.land/r/upgrade/amm/v1
