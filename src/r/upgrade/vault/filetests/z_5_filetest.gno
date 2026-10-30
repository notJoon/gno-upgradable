// PKGPATH: gno.land/r/demo/main

// The API only grows. The proxy answers only the methods the implementation
// lists, and refuses a new implementation that lacks any method ever
// served. Only a rollback may leave methods out.
package main

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

// noWithdraw drops Withdraw.
type noWithdraw struct{ v1.Impl }

func (noWithdraw) Methods() (calls, queries []string) {
	return []string{"Deposit"}, []string{"BalanceOf"}
}

// moved turns the BalanceOf query into a call.
type moved struct{ v1.Impl }

func (moved) Methods() (calls, queries []string) {
	return []string{"Deposit", "Withdraw", "BalanceOf"}, nil
}

// retired keeps CollectFees listed but retires it.
type retired struct{ v1.Impl }

func (retired) Methods() (calls, queries []string) {
	return []string{"Deposit", "Withdraw", "CollectFees"}, []string{"BalanceOf"}
}

func (r retired) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	if method == "CollectFees" {
		panic("vault: CollectFees was retired")
	}
	return r.Impl.Call(tx, c, method, args)
}

// approve approves path. The caller then has it Prepare and waits.
func approve(cur realm, path string) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), path)
}

// noFees is v1 as a new implementation: it lacks v2's CollectFees.
type noFees struct{ v1.Impl }

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	self := testing.NewCodeRealm("gno.land/r/demo/main")
	v1.Activate(cross(cur))
	println(vault.Methods())

	// Unlisted names are refused before the implementation runs.
	testing.SetRealm(testing.NewUserRealm(alice))
	println(revive(func() { vault.Call(cross(cur), "BalanceOf", alice.String()) }))
	println(revive(func() { vault.Query("Deposit", "") }))

	// Missing tells an implementation what it lacks before approval.
	println(vault.Missing(noWithdraw{}))
	println(vault.Missing(moved{}))

	// Prepare with a whole implementation, then register lacking ones:
	// Register checks again, since it may be handed a different value.
	approve(cur, "gno.land/r/demo/main")
	testing.SetRealm(self)
	vault.Prepare(cross(cur), noFees{})
	testing.SkipHeights(vault.UpgradeDelay)
	println(revive(func() { vault.Register(cross(cur), noWithdraw{}) }))
	println(revive(func() { vault.Register(cross(cur), moved{}) }))
	// A refused registration changes nothing.
	println("impl:", vault.ImplPath(), "approved:", vault.Approved())

	// Rolling back from v2 to v1 leaves CollectFees out, but it stays in
	// the API, so the next new implementation must answer it.
	approve(cur, "gno.land/r/upgrade/vault/v2")
	v2.Prepare(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Activate(cross(cur))
	approve(cur, "gno.land/r/upgrade/vault/v1")
	v1.Prepare(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay)
	v1.Activate(cross(cur))
	println("impl:", vault.ImplPath())
	println(vault.Methods())
	println(vault.API())

	approve(cur, "gno.land/r/demo/main")
	testing.SetRealm(self)
	vault.Prepare(cross(cur), retired{})
	testing.SkipHeights(vault.UpgradeDelay)
	println(revive(func() { vault.Register(cross(cur), noFees{}) }))
	// Retiring keeps the name and fails with a reason.
	vault.Register(cross(cur), retired{})
	println("impl:", vault.ImplPath())
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	println(revive(func() { vault.Call(cross(cur), "CollectFees", "") }))
}

// Output:
// slice[("Deposit" string),("Withdraw" string)] slice[("BalanceOf" string)]
// upgrade: unknown method BalanceOf
// upgrade: unknown method Deposit
// slice[("Withdraw" string)] (nil []string)
// (nil []string) slice[("BalanceOf" string)]
// upgrade: next implementation lacks API methods: Call Withdraw; to retire one, keep it and make it panic
// upgrade: next implementation lacks API methods: Query BalanceOf; to retire one, keep it and make it panic
// impl: gno.land/r/upgrade/vault/v1 approved: gno.land/r/demo/main
// impl: gno.land/r/upgrade/vault/v1
// slice[("Deposit" string),("Withdraw" string)] slice[("BalanceOf" string)]
// slice[("Deposit" string),("Withdraw" string),("CollectFees" string)] slice[("BalanceOf" string)]
// upgrade: next implementation lacks API methods: Call CollectFees; to retire one, keep it and make it panic
// impl: gno.land/r/demo/main
// vault: CollectFees was retired
