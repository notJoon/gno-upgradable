// PKGPATH: gno.land/r/demo/main

// Upgrading from v1 to v2 keeps the vault's address, coins and balances,
// v2 adds a method without changing the vault, and an old implementation
// cannot take control back.
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

const admin address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	vaultAddr := chain.PackageAddress("gno.land/r/upgrade/vault")
	bnk := banker.NewReadonlyBanker()

	v1.Bootstrap(cross(cur))
	println("impl:", vault.ImplPath())

	// alice deposits 1000ugnot through a direct call.
	testing.IssueCoins(vaultAddr, chain.Coins{{"ugnot", 1000}})
	testing.SetOriginSend(chain.Coins{{"ugnot", 1000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	vault.Call(cross(cur), "Deposit", "")
	testing.SetOriginSend(nil)
	vault.Call(cross(cur), "Withdraw", "200")
	println("v1 alice balance:", vault.Query("BalanceOf", alice.String()), "coins:", bnk.GetCoin(alice, "ugnot"))

	// v1 has no CollectFees.
	println(revive(func() { vault.Call(cross(cur), "CollectFees", "") }))

	// v2 is not approved yet.
	println(revive(func() { v2.Activate(cross(cur)) }))

	testing.SetRealm(testing.NewUserRealm(admin))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	println("approved:", vault.Approved())
	v2.Prepare(cross(cur))
	// v2 must wait out the delay while v1 is live.
	println(revive(func() { v2.Activate(cross(cur)) }))
	testing.SkipHeights(vault.UpgradeDelay)
	v2.Activate(cross(cur))
	println("impl:", vault.ImplPath())

	// Balances carry over, and v2 charges a 1% fee.
	testing.SetRealm(testing.NewUserRealm(alice))
	println("v2 alice balance:", vault.Query("BalanceOf", alice.String()))
	vault.Call(cross(cur), "Withdraw", "500")
	println("v2 alice balance:", vault.Query("BalanceOf", alice.String()), "coins:", bnk.GetCoin(alice, "ugnot"))
	println("vault coins:", bnk.GetCoin(vaultAddr, "ugnot"))
	println(vault.Render(""))

	// The fees are no longer stuck: only the admin can collect them.
	println(revive(func() { vault.Call(cross(cur), "CollectFees", "") }))
	testing.SetRealm(testing.NewUserRealm(admin))
	vault.Call(cross(cur), "CollectFees", "")
	println("admin coins:", bnk.GetCoin(admin, "ugnot"), "vault coins:", bnk.GetCoin(vaultAddr, "ugnot"))

	// v1 is still on chain but cannot register again.
	println(revive(func() { v1.Activate(cross(cur)) }))
	println("impl:", vault.ImplPath())
}

// Output:
// impl: gno.land/r/upgrade/vault/v1
// v1 alice balance: 800 coins: 200
// upgrade: unknown method CollectFees
// upgrade: caller is not the approved implementation
// approved: gno.land/r/upgrade/vault/v2
// upgrade: approval is still in its delay
// impl: gno.land/r/upgrade/vault/v2
// v2 alice balance: 800
// v2 alice balance: 300 coins: 695
// vault coins: 305
// # Vault
//
// Fees collected: 5ugnot
//
// vault: only the admin collects fees
// admin coins: 5 vault coins: 300
// upgrade: caller is not the approved implementation
// impl: gno.land/r/upgrade/vault/v2
