// PKGPATH: gno.land/r/demo/main

// v2 can be rolled back to from a newer version, so its Migrate must accept
// any predecessor, not only v1.
package main

import (
	"testing"

	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

// v3 answers the whole API v2 left.
type v3 struct{ v1.Impl }

func (v3) Methods() (calls, queries []string) {
	return []string{"Deposit", "Withdraw", "CollectFees"}, []string{"BalanceOf"}
}

func approve(cur realm, path string) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), path)
}

func main(cur realm) {
	v1.Activate(cross(cur))

	approve(cur, "gno.land/r/upgrade/vault/v2")
	v2.Prepare(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Activate(cross(cur))

	approve(cur, "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	vault.Prepare(cross(cur), v3{})
	testing.SkipHeights(vault.UpgradeDelay)
	vault.Register(cross(cur), v3{})
	println("impl:", vault.ImplPath())

	approve(cur, "gno.land/r/upgrade/vault/v2")
	v2.Prepare(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Activate(cross(cur))
	println("impl:", vault.ImplPath())
}

// Output:
// impl: gno.land/r/demo/main
// impl: gno.land/r/upgrade/vault/v2
