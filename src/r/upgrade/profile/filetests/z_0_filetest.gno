// PKGPATH: gno.land/r/demo/main

// v2 adds a field to the record. A rollback to v1 rewrites the record and
// keeps that field, and back on v2, field 1 shows that v1 wrote last.
package main

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/profile"
	v1 "gno.land/r/upgrade/profile/v1"
	v2 "gno.land/r/upgrade/profile/v2"
)

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(profile.Admin0))
	profile.Approve(cross(cur), "gno.land/r/upgrade/profile/v1")
	v1.Upgrade(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	profile.SetName(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	profile.SetName(cross(cur), "bob")
	println("v1:", profile.Show(alice))

	// v2 reads v1's records as they are. Bob's has no height yet.
	testing.SetRealm(testing.NewUserRealm(profile.Admin0))
	profile.Approve(cross(cur), "gno.land/r/upgrade/profile/v2")
	v2.Upgrade(cross(cur))
	testing.SkipHeights(profile.UpgradeDelay)
	v2.Upgrade(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	profile.SetName(cross(cur), "Alice")
	println("v2:", profile.Show(alice), "|", profile.Show(bob))

	// v1 rewrites Alice's record and keeps the height it does not know.
	testing.SetRealm(testing.NewUserRealm(profile.Admin0))
	profile.Approve(cross(cur), "gno.land/r/upgrade/profile/v1")
	v1.Upgrade(cross(cur))
	testing.SkipHeights(profile.UpgradeDelay)
	v1.Upgrade(cross(cur))
	testing.SetRealm(testing.NewUserRealm(alice))
	profile.SetName(cross(cur), "Alice Liddell")
	println("v1:", profile.Show(alice))

	// Back on v2 the height survived, and field 1 says v1 changed the name
	// since, so the height is only a lower bound.
	testing.SetRealm(testing.NewUserRealm(profile.Admin0))
	profile.Approve(cross(cur), "gno.land/r/upgrade/profile/v2")
	v2.Upgrade(cross(cur))
	testing.SkipHeights(profile.UpgradeDelay)
	v2.Upgrade(cross(cur))
	println("v2:", profile.Show(alice))
	testing.SetRealm(testing.NewUserRealm(alice))
	profile.SetName(cross(cur), "Alice")
	println("v2:", profile.Show(alice))
}

// Output:
// v1: alice
// v2: Alice, changed at block 17403 | bob
// v1: Alice Liddell
// v2: Alice Liddell, changed after block 17403
// v2: Alice, changed at block 51963
