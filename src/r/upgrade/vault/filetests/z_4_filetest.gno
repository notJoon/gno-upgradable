// PKGPATH: gno.land/r/demo/main

// Rolling back is an ordinary upgrade to the old realm: it waits the delay,
// keeps balances and coins, and leaves the newer version's tables for when
// it comes back. Methods the old realm lacks are unavailable meanwhile.
package main

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

func upgradeTo(cur realm, path string, activate func()) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), path)
	println(revive(activate))
	testing.SkipHeights(vault.UpgradeDelay)
	activate()
	println("impl:", vault.ImplPath())
}

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	vaultAddr := chain.PackageAddress("gno.land/r/upgrade/vault")
	bnk := banker.NewReadonlyBanker()
	v1.Activate(cross(cur))

	testing.IssueCoins(vaultAddr, chain.Coins{{"ugnot", 1000}})
	testing.SetOriginSend(chain.Coins{{"ugnot", 1000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	vault.Call(cross(cur), "Deposit", "")
	testing.SetOriginSend(nil)

	upgradeTo(cur, "gno.land/r/upgrade/vault/v2", func() { v2.Activate(cross(cur)) })
	testing.SetRealm(testing.NewUserRealm(alice))
	vault.Call(cross(cur), "Withdraw", "100") // 1 fee
	println("v2 alice coins:", bnk.GetCoin(alice, "ugnot"))

	// Back to v1, after the same delay as any upgrade. v1 has no
	// CollectFees, which a rollback is allowed to leave out.
	upgradeTo(cur, "gno.land/r/upgrade/vault/v1", func() { v1.Activate(cross(cur)) })
	testing.SetRealm(testing.NewUserRealm(alice))
	println("v1 alice balance:", vault.Query("BalanceOf", alice.String()))
	vault.Call(cross(cur), "Withdraw", "100") // no fee
	println("v1 alice coins:", bnk.GetCoin(alice, "ugnot"), "vault coins:", bnk.GetCoin(vaultAddr, "ugnot"))
	println(revive(func() { vault.Call(cross(cur), "CollectFees", "") }))

	// Forward to v2 again: the fee v2 collected is still there.
	upgradeTo(cur, "gno.land/r/upgrade/vault/v2", func() { v2.Activate(cross(cur)) })
	println(vault.Render(""))
}

// Output:
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v2
// v2 alice coins: 99
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v1
// v1 alice balance: 900
// v1 alice coins: 199 vault coins: 801
// upgrade: CollectFees is unavailable under the current implementation
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v2
// # Vault
//
// Fees collected: 1ugnot
