// PKGPATH: gno.land/r/demo/main

// The vault itself shows a pending upgrade or a freeze above whatever the
// implementation renders, so no implementation can hide one.
package main

import (
	"testing"

	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

func main(cur realm) {
	v1.Activate(cross(cur))
	println(vault.Render(""))

	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	println(vault.Render(""))
	v2.Prepare(cross(cur))
	println(vault.Render(""))

	testing.SkipHeights(vault.UpgradeDelay)
	v2.Activate(cross(cur))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Prepare(cross(cur))
	println(vault.Render(""))

	vault.Freeze(cross(cur))
	println(vault.Render(""))
}

// Output:
// # Vault
//
// > [!WARNING]
// > Upgrade approved: `gno.land/r/upgrade/vault/v2`. Its delay of 17280 blocks starts when it calls Prepare.
//
// # Vault
//
// > [!WARNING]
// > Upgrade pending: `gno.land/r/upgrade/vault/v2` can take over at block 17403.
//
// # Vault
//
// > [!WARNING]
// > Rollback pending: `gno.land/r/upgrade/vault/v1` can take over at block 34683.
//
// # Vault
//
// Fees collected: 0ugnot
//
// > [!NOTE]
// > Upgrades are frozen. `gno.land/r/upgrade/vault/v2` serves for good.
//
// # Vault
//
// Fees collected: 0ugnot
