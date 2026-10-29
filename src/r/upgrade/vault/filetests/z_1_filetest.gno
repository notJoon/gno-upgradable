// PKGPATH: gno.land/r/demo/main

// Calls the vault must refuse.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

type fakeImpl struct{ upgrade.Impl }

func main(cur realm) {
	alice := testutils.TestAddress("alice")

	// Nothing is registered before v1 activates.
	println(revive(func() { vault.Query("BalanceOf", alice.String()) }))

	// Only the approved realm can register, not whoever calls Register.
	println(revive(func() { vault.Register(cross(cur), fakeImpl{}) }))
	v1.Activate(cross(cur))

	// Only the admin can approve.
	testing.SetRealm(testing.NewUserRealm(alice))
	println(revive(func() { vault.Approve(cross(cur), "gno.land/r/demo/main") }))

	// Unknown methods and bad arguments are refused.
	println(revive(func() { vault.Call(cross(cur), "Nope", "") }))
	println(revive(func() { vault.Call(cross(cur), "Withdraw", "-1") }))

	// Coins sent with a method that does not take them go back.
	testing.IssueCoins(chain.PackageAddress("gno.land/r/upgrade/vault"), chain.Coins{{"ugnot", 100}})
	testing.SetOriginSend(chain.Coins{{"ugnot", 100}})
	vault.Call(cross(cur), "Deposit", "")
	println(revive(func() { vault.Call(cross(cur), "Withdraw", "1") }))

	// Deposits must come straight from a user, not through a code realm.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	println(revive(func() { vault.Call(cross(cur), "Deposit", "") }))
}

// Output:
// upgrade: no implementation registered
// upgrade: caller is not the approved implementation
// upgrade: caller is not the owner
// upgrade: unknown method Nope
// vault: amount must be a positive integer
// upgrade: method did not take the coins sent with it
// vault: send only ugnot to deposit
