// PKGPATH: gno.land/r/demo/main

// A swap callback cannot read the pool, which mid-swap has sent the output
// but not yet updated its reserves. A price read there would be wrong.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/amm"
	v1 "gno.land/r/upgrade/amm/v1"
	"gno.land/r/upgrade/testtoken"
)

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	pool := chain.PackageAddress("gno.land/r/upgrade/amm")
	self := chain.PackageAddress("gno.land/r/demo/main")
	v1.Bootstrap(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	testtoken.Faucet(cross(cur), 1000)
	testtoken.Approve(cross(cur), "A", pool, 1000)
	testtoken.Approve(cross(cur), "B", pool, 1000)
	amm.Call(cross(cur), "AddLiquidity", "1000 1000")

	// Outside a swap both read as usual. This comes first because a reverted
	// swap leaves the lock set under revive, which only filetests have: on
	// chain the panic aborts the whole transaction.
	r0, r1 := amm.Reserves()
	println("reserves:", r0, r1, "alice shares:", amm.Query("SharesOf", alice.String()))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	testtoken.Faucet(cross(cur), 1000)
	pay := func(cur realm, owed int64) {
		must(testtoken.A.RealmTeller(0, cur).Transfer(0, cur, pool, owed))
	}
	reserves := func(cur realm, owed int64, _ *amm.CallbackMarker) {
		amm.Reserves()
		pay(cur, owed)
	}
	println(revive(func() { amm.Swap(cross(cur), true, 100, 1, self, reserves) }))
	query := func(cur realm, owed int64, _ *amm.CallbackMarker) {
		amm.Query("SharesOf", alice.String())
		pay(cur, owed)
	}
	println(revive(func() { amm.Swap(cross(cur), true, 100, 1, self, query) }))
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// Output:
// reserves: 1000 1000 alice shares: 1000
// amm: reentrant call
// amm: reentrant call
