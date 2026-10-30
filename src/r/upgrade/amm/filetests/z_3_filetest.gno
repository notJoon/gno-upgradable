// PKGPATH: gno.land/r/demo/main

// An implementation cannot leave a token allowance behind after its call.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/amm"
	v1 "gno.land/r/upgrade/amm/v1"
	"gno.land/r/upgrade/testtoken"
)

type next struct{ v1.Impl }

func (n next) Methods() (calls, queries []upgrade.Method) {
	calls, queries = n.Impl.Methods()
	return append(calls, upgrade.Method{Name: "ApproveA", Schema: "v1:void->void"}), queries
}

func (n next) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	if method == "ApproveA" {
		c.ApproveForCall(testtoken.A, chain.PackageAddress("gno.land/r/demo/main"), 100)
		return ""
	}
	return n.Impl.Call(tx, c, method, args)
}

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
	amm.Upgrade(cross(cur), next{})

	amm.Call(cross(cur), "ApproveA", "")
	println("allowance:", testtoken.A.Allowance(pool, self))
	println(testtoken.A.RealmTeller(0, cur).TransferFrom(0, cur, pool, self, 1))
}

// Output:
// allowance: 0
// insufficient allowance
