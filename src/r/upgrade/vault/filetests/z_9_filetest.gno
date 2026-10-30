// PKGPATH: gno.land/r/demo/main

// v2 can be rolled back to from a newer version, so its Migrate must accept
// any predecessor, not only v1.
package main

import (
	"testing"

	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

// v3 answers the whole API v2 left.
type v3 struct{ v1.Impl }

func (v3) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{
		{Name: "Deposit", Schema: "v1:void->void"},
		{Name: "Withdraw", Schema: "v1:int64->void"},
		{Name: "CollectFees", Schema: "v1:void->void"},
	}, []upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
}

func approve(cur realm, path string) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), path)
}

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))

	approve(cur, "gno.land/r/upgrade/vault/v2")
	v2.Upgrade(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Upgrade(cross(cur))

	approve(cur, "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	vault.Upgrade(cross(cur), v3{})
	testing.SkipHeights(vault.UpgradeDelay)
	vault.Upgrade(cross(cur), v3{})
	println("impl:", vault.ImplPath())

	approve(cur, "gno.land/r/upgrade/vault/v2")
	v2.Upgrade(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Upgrade(cross(cur))
	println("impl:", vault.ImplPath())
}

// Output:
// impl: gno.land/r/demo/main
// impl: gno.land/r/upgrade/vault/v2
