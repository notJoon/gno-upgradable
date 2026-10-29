// PKGPATH: gno.land/r/demo/main

// A user and a realm both add liquidity by approving the pool, which pulls
// the tokens. The realm then swaps through a callback that pushes payment,
// and the pool checks its balance rose. Underpaying and reentering fail.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/amm"
	v1 "gno.land/r/upgrade/amm/v1"
	"gno.land/r/upgrade/testtoken"
)

const ammPath = "gno.land/r/upgrade/amm"

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	pool := chain.PackageAddress(ammPath)
	self := chain.PackageAddress("gno.land/r/demo/main")
	v1.Activate(cross(cur))

	// alice adds liquidity from her account.
	testing.SetRealm(testing.NewUserRealm(alice))
	testtoken.Faucet(cross(cur), 1000)
	testtoken.Approve(cross(cur), "A", pool, 1000)
	testtoken.Approve(cross(cur), "B", pool, 1000)
	println("alice shares:", amm.Call(cross(cur), "AddLiquidity", "1000 1000"))

	// This realm adds liquidity too. It approves with its own teller, and the
	// pool pulls from the realm's address.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	testtoken.Faucet(cross(cur), 1000)
	must(testtoken.A.RealmTeller(0, cur).Approve(0, cur, pool, 100))
	must(testtoken.B.RealmTeller(0, cur).Approve(0, cur, pool, 100))
	println("realm shares:", amm.Call(cross(cur), "AddLiquidity", "100 100"))
	r0, r1 := amm.Reserves()
	println("reserves:", r0, r1)

	// Swap 100 A for B. The callback pays with this realm's own teller.
	pay := func(cur realm, owed int64, _ *amm.CallbackMarker) {
		if cur.Previous().PkgPath() != ammPath {
			panic("callback must come from the pool")
		}
		must(testtoken.A.RealmTeller(0, cur).Transfer(0, cur, pool, owed))
	}
	out := amm.Swap(cross(cur), true, 100, 1, self, pay)
	r0, r1 = amm.Reserves()
	println("swap out:", out, "reserves:", r0, r1)
	println("pool A:", testtoken.A.BalanceOf(pool), "B:", testtoken.B.BalanceOf(pool))

	underpay := func(cur realm, owed int64, _ *amm.CallbackMarker) {
		must(testtoken.A.RealmTeller(0, cur).Transfer(0, cur, pool, owed-1))
	}
	println(revive(func() { amm.Swap(cross(cur), true, 100, 1, self, underpay) }))

	reenter := func(cur realm, owed int64, _ *amm.CallbackMarker) {
		amm.Call(cross(cur), "AddLiquidity", "1 1")
	}
	println(revive(func() { amm.Swap(cross(cur), true, 100, 1, self, reenter) }))
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// Output:
// alice shares: 1000
// realm shares: 100
// reserves: 1100 1100
// swap out: 91 reserves: 1200 1009
// pool A: 1200 B: 1009
// amm: callback underpaid
// amm: reentrant call
