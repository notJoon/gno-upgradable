// PKGPATH: gno.land/r/demo/main

// With an implementation live, the delay starts only when the approved realm
// first calls Upgrade, which it cannot do before its code is deployed. So
// users always get the whole delay to read the code that will take over.
package main

import (
	"chain/runtime"
	"testing"

	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

// noWithdraw drops Withdraw.
type noWithdraw struct{ v1.Impl }

func (noWithdraw) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{{Name: "Deposit", Schema: "v1:void->void"}},
		[]upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
}

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))

	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	println("eta before the first call:", vault.ApprovedETA())

	// Only the approved realm may start the delay.
	println(revive(func() { v1.Upgrade(cross(cur)) }))

	// Time spent before the first call does not count: it starts the delay
	// and installs nothing.
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Upgrade(cross(cur))
	eta := vault.ApprovedETA()
	println("impl:", vault.ImplPath(), "eta is a whole delay away:", eta == runtime.ChainHeight()+vault.UpgradeDelay)

	// Anyone can call v2.Upgrade, so a second call must not push the ETA back.
	testing.SkipHeights(vault.UpgradeDelay - 1)
	println(revive(func() { v2.Upgrade(cross(cur)) }))
	println("eta unchanged:", vault.ApprovedETA() == eta)
	testing.SkipHeights(1)
	v2.Upgrade(cross(cur))
	println("impl:", vault.ImplPath())

	// The first call checks the API, so a lacking implementation fails now
	// rather than once the delay has passed.
	vault.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	println(revive(func() { vault.Upgrade(cross(cur), noWithdraw{}) }))
}

// Output:
// eta before the first call: 0
// upgrade: caller is not the approved implementation
// impl: gno.land/r/upgrade/vault/v1 eta is a whole delay away: true
// upgrade: approval is still in its delay
// eta unchanged: true
// impl: gno.land/r/upgrade/vault/v2
// upgrade: next implementation lacks API methods: Call Withdraw [v1:int64->void], Call CollectFees [v1:void->void]; to retire one, keep it and make it panic
