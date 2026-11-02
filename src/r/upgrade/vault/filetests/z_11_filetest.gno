// PKGPATH: gno.land/r/demo/main

// A prepared upgrade must install within UpgradeWindow blocks of its ETA.
// Past that, users' review of the code is stale, so it cannot land until the
// admin approves it again, which restarts the whole delay.
package main

import (
	"strings"
	"testing"

	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))

	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	v2.Upgrade(cross(cur))

	// The last block of the window still installs.
	testing.SkipHeights(vault.UpgradeDelay + vault.UpgradeWindow)
	println(strings.SplitN(vault.Render(""), "\n\n", 2)[0])
	v2.Upgrade(cross(cur))
	println("boundary impl:", vault.ImplPath())

	// The following block is expired.
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))
	testing.SkipHeights(vault.UpgradeDelay + vault.UpgradeWindow + 1)
	println(revive(func() { v1.Upgrade(cross(cur)) }))
	println(strings.SplitN(vault.Render(""), "\n\n", 2)[0])

	// Approving again restarts the delay from the next Upgrade call.
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))
	println(revive(func() { v1.Upgrade(cross(cur)) }))
	testing.SkipHeights(vault.UpgradeDelay + vault.UpgradeWindow)
	v1.Upgrade(cross(cur))
	println("impl:", vault.ImplPath())
}

// Output:
// > [!WARNING]
// > Upgrade pending: `gno.land/r/upgrade/vault/v2` can take over from block 17403 until block 34683.
// boundary impl: gno.land/r/upgrade/vault/v2
// upgrade: approval expired, the owner must approve again
// > [!NOTE]
// > Rollback to `gno.land/r/upgrade/vault/v1` expired at block 69243. It cannot land unless the owner approves it again.
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v1
