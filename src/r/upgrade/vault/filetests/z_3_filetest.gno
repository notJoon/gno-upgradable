// PKGPATH: gno.land/r/demo/main

// Freeze ends upgrades for good, and only the admin can do it.
package main

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

type fake struct{ v1.Impl }

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	println(revive(func() { vault.Freeze(cross(cur)) }))
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	println(revive(func() { vault.Freeze(cross(cur)) }))
	println(revive(func() { vault.TransferAdmin(cross(cur), alice) }))

	// Freezing drops the pending approval.
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/demo/main")
	vault.Freeze(cross(cur))
	println("frozen:", vault.Frozen(), "approved:", vault.Approved() == "")
	println(revive(func() { vault.Approve(cross(cur), "gno.land/r/demo/main") }))

	testing.SkipHeights(vault.UpgradeDelay)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	println(revive(func() { vault.Upgrade(cross(cur), nil) }))
	println("impl:", vault.ImplPath())

	// The admin role still moves, for implementations that gate on it.
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.TransferAdmin(cross(cur), alice)
	println("admin unchanged:", vault.Admin() == vault.Admin0)
	testing.SetRealm(testing.NewUserRealm(bob))
	println(revive(func() { vault.AcceptAdmin(cross(cur)) }))
	testing.SetRealm(testing.NewUserRealm(alice))
	vault.AcceptAdmin(cross(cur))
	println("admin is alice:", vault.Admin() == alice)
}

// Output:
// upgrade: nothing to freeze before the first implementation
// upgrade: caller is not the owner
// upgrade: caller is not the owner
// frozen: true approved: true
// upgrade: upgrades are frozen
// upgrade: caller is not the approved implementation
// impl: gno.land/r/upgrade/vault/v1
// admin unchanged: true
// upgrade: caller is not the pending owner
// admin is alice: true
