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

	// The last block of the window still installs, so skip one past it.
	testing.SkipHeights(vault.UpgradeDelay + vault.UpgradeWindow)
	println(revive(func() { v2.Upgrade(cross(cur)) }))
	println(strings.SplitN(vault.Render(""), "\n\n", 2)[0])

	// Approving again restarts the delay from the next Upgrade call.
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	v2.Upgrade(cross(cur))
	println(revive(func() { v2.Upgrade(cross(cur)) }))
	testing.SkipHeights(vault.UpgradeDelay + vault.UpgradeWindow - 1)
	v2.Upgrade(cross(cur))
	println("impl:", vault.ImplPath())
}

// Output:
// upgrade: approval expired, the owner must approve again
// > [!NOTE]
// > Upgrade to `gno.land/r/upgrade/vault/v2` expired at block 34683. It cannot land unless the owner approves it again.
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v2
