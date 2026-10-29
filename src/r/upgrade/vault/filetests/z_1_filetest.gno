// PKGPATH: gno.land/r/demo/main

// Calls the vault must refuse.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

type fakeImpl struct{ vault.Impl }

func main(cur realm) {
	alice := testutils.TestAddress("alice")

	// Nothing is registered before v1 activates.
	println(revive(func() { vault.BalanceOf(alice) }))

	// Only the approved realm can register, not whoever calls Register.
	println(revive(func() { vault.Register(cross(cur), fakeImpl{}) }))
	v1.Activate(cross(cur))

	// Only the admin can approve.
	testing.SetRealm(testing.NewUserRealm(alice))
	println(revive(func() { vault.Approve(cross(cur), "gno.land/r/demo/main") }))

	// Deposits must come straight from a user, not through a code realm.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 100}})
	println(revive(func() { vault.Deposit(cross(cur)) }))
}

// Output:
// vault: no implementation registered
// upgrade: caller is not the approved implementation
// ownable: caller is not owner
// vault: deposit must be a direct user call
