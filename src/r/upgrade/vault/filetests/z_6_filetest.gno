// PKGPATH: gno.land/r/demo/main

// With an implementation live, the delay starts only when the approved realm
// calls Prepare, which it cannot do before its code is deployed. So users
// always get the whole delay to read the code that will take over.
package main

import (
	"chain/runtime"
	"testing"

	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

// noWithdraw drops Withdraw.
type noWithdraw struct{ v1.Impl }

func (noWithdraw) Methods() (calls, queries []string) {
	return []string{"Deposit"}, []string{"BalanceOf"}
}

func main(cur realm) {
	v1.Activate(cross(cur))

	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	println("eta before prepare:", vault.ApprovedETA())

	// Time spent before Prepare does not count.
	testing.SkipHeights(vault.UpgradeDelay)
	println(revive(func() { v2.Activate(cross(cur)) }))

	// Only the approved realm may prepare.
	println(revive(func() { v1.Prepare(cross(cur)) }))

	v2.Prepare(cross(cur))
	println("eta is a whole delay away:", vault.ApprovedETA() == runtime.ChainHeight()+vault.UpgradeDelay)
	// Anyone can call v2.Prepare, so a second call must not push the ETA back.
	println(revive(func() { v2.Prepare(cross(cur)) }))

	testing.SkipHeights(vault.UpgradeDelay - 1)
	println(revive(func() { v2.Activate(cross(cur)) }))
	testing.SkipHeights(1)
	v2.Activate(cross(cur))
	println("impl:", vault.ImplPath())

	// Prepare checks the API, so a lacking implementation fails now rather
	// than once the delay has passed.
	vault.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	println(revive(func() { vault.Prepare(cross(cur), noWithdraw{}) }))
}

// Output:
// eta before prepare: 0
// upgrade: approved implementation has not called Prepare
// upgrade: caller is not the approved implementation
// eta is a whole delay away: true
// upgrade: approval is already prepared
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v2
// upgrade: next implementation lacks API methods: Call Withdraw, Call CollectFees; to retire one, keep it and make it panic
