// PKGPATH: gno.land/r/demo/main

// Typed implementations upgrade from v1 to v2 with no string dispatch. v1 has
// no Render, so only the banner shows. v2's Migrate totals v1's rows.
package main

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/counter"
	v1 "gno.land/r/upgrade/counter/v1"
	v2 "gno.land/r/upgrade/counter/v2"
)

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(counter.Admin0))
	counter.Approve(cross(cur), "gno.land/r/upgrade/counter/v1")
	v1.Bootstrap(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	counter.Inc(cross(cur))
	counter.Inc(cross(cur))
	testing.SetRealm(testing.NewUserRealm(bob))
	counter.Inc(cross(cur))
	println(counter.ImplID(), counter.Get(alice), counter.Get(bob))

	testing.SetRealm(testing.NewUserRealm(counter.Admin0))
	counter.Approve(cross(cur), "gno.land/r/upgrade/counter/v2")
	v2.Prepare(cross(cur))
	print(counter.Render(""))
	testing.SkipHeights(counter.UpgradeDelay)
	v2.Activate(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	counter.Inc(cross(cur))
	println(counter.ImplID(), counter.Get(alice), counter.Get(bob))
	print(counter.Render(""))
}

// Output:
// gno.land/r/upgrade/counter/v1:impl 2 1
// > [!WARNING]
// > Upgrade pending: `gno.land/r/upgrade/counter/v2` can take over at block 17403.
//
// gno.land/r/upgrade/counter/v2:impl 3 1
// # Counter
//
// Total: 4
