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

func (noWithdraw) ID() string { return "gno.land/r/demo/main:no-withdraw" }

func (noWithdraw) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{{Name: "Deposit", Schema: "v1:void->void"}},
		[]upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
}

// moved turns the BalanceOf query into a call.
type moved struct{ v1.Impl }

func (moved) ID() string { return "gno.land/r/demo/main:moved" }

func (moved) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{
		{Name: "Deposit", Schema: "v1:void->void"},
		{Name: "Withdraw", Schema: "v1:int64->void"},
		{Name: "BalanceOf", Schema: "v1:address->int64"},
	}, nil
}

// changedSchema keeps Withdraw's name but changes its caller contract.
type changedSchema struct{ v1.Impl }

func (changedSchema) ID() string { return "gno.land/r/demo/main:changed-schema" }

func (changedSchema) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{
		{Name: "Deposit", Schema: "v1:void->void"},
		{Name: "Withdraw", Schema: "v2:json->void"},
	}, []upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
}

// retired keeps CollectFees listed but retires it.
type retired struct{ v1.Impl }

func (retired) ID() string { return "gno.land/r/demo/main:retired" }

func (retired) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{
		{Name: "Deposit", Schema: "v1:void->void"},
		{Name: "Withdraw", Schema: "v1:int64->void"},
		{Name: "CollectFees", Schema: "v1:void->void"},
	}, []upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
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

func (noFees) ID() string { return "gno.land/r/demo/main:no-fees" }

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	self := testing.NewCodeRealm("gno.land/r/demo/main")
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Bootstrap(cross(cur))
	println(vault.Methods())
	println("identity:", vault.ImplID(), len(vault.ManifestHash()))

	// Unlisted names are refused before the implementation runs.
	testing.SetRealm(testing.NewUserRealm(alice))
	println(revive(func() { vault.Call(cross(cur), "BalanceOf", alice.String()) }))
	println(revive(func() { vault.Query("Deposit", "") }))

	// Missing tells an implementation what it lacks before approval.
	println(vault.Missing(noWithdraw{}))
	println(vault.Missing(moved{}))
	println(vault.Missing(changedSchema{}))

	// Register activates the exact implementation saved by Prepare.
	approve(cur, "gno.land/r/demo/main")
	testing.SetRealm(self)
	vault.Prepare(cross(cur), noFees{})
	println("pending identity:", vault.PendingImplID(), vault.PendingManifestHash() != "")
	testing.SkipHeights(vault.UpgradeDelay)
	vault.Register(cross(cur))
	println("impl:", vault.ImplPath())

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
	// A realm path that served before gets the rollback exception only for
	// the same implementation ID.
	println(revive(func() { vault.Prepare(cross(cur), noWithdraw{}) }))
	vault.Prepare(cross(cur), retired{})
	testing.SkipHeights(vault.UpgradeDelay)
	// Retiring keeps the name and fails with a reason.
	vault.Register(cross(cur))
	println("impl:", vault.ImplPath())
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	println(revive(func() { vault.Call(cross(cur), "CollectFees", "") }))
}

// Output:
// slice[(struct{("Deposit" string),("v1:void->void" string)} gno.land/p/upgrade/v0.Method),(struct{("Withdraw" string),("v1:int64->void" string)} gno.land/p/upgrade/v0.Method)] slice[(struct{("BalanceOf" string),("v1:address->int64" string)} gno.land/p/upgrade/v0.Method)]
// identity: gno.land/r/upgrade/vault/v1:impl 64
// upgrade: unknown method BalanceOf
// upgrade: unknown method Deposit
// slice[(struct{("Withdraw" string),("v1:int64->void" string)} gno.land/p/upgrade/v0.Method)] (nil []gno.land/p/upgrade/v0.Method)
// (nil []gno.land/p/upgrade/v0.Method) slice[(struct{("BalanceOf" string),("v1:address->int64" string)} gno.land/p/upgrade/v0.Method)]
// slice[(struct{("Withdraw" string),("v1:int64->void" string)} gno.land/p/upgrade/v0.Method)] (nil []gno.land/p/upgrade/v0.Method)
// pending identity: gno.land/r/demo/main:no-fees true
// impl: gno.land/r/demo/main
// impl: gno.land/r/upgrade/vault/v1
// slice[(struct{("Deposit" string),("v1:void->void" string)} gno.land/p/upgrade/v0.Method),(struct{("Withdraw" string),("v1:int64->void" string)} gno.land/p/upgrade/v0.Method)] slice[(struct{("BalanceOf" string),("v1:address->int64" string)} gno.land/p/upgrade/v0.Method)]
// slice[(struct{("Deposit" string),("v1:void->void" string)} gno.land/p/upgrade/v0.Method),(struct{("Withdraw" string),("v1:int64->void" string)} gno.land/p/upgrade/v0.Method),(struct{("CollectFees" string),("v1:void->void" string)} gno.land/p/upgrade/v0.Method)] slice[(struct{("BalanceOf" string),("v1:address->int64" string)} gno.land/p/upgrade/v0.Method)]
// upgrade: next implementation lacks API methods: Call Withdraw [v1:int64->void], Call CollectFees [v1:void->void]; to retire one, keep it and make it panic
// impl: gno.land/r/demo/main
// vault: CollectFees was retired
