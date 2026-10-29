// Package vault (v2) is the second implementation of "gno.land/r/upgrade/vault".
// It reads v1's balances unchanged and adds a 1% withdrawal fee.
// total is new state, kept under a key of its own in the vault's store,
// so the vault itself did not change.
package vault

import (
	"chain"
	"chain/banker"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	proxy "gno.land/r/upgrade/vault"
)

const feesKey = "fees"

// Activate makes v2 the vault's implementation. It succeeds only
// while the vault has approved this realm.
func Activate(cur realm) {
	proxy.Register(cross(cur), impl{})
}

type impl struct{}

func (impl) Deposit(store *avl.Tree, rlm realm, amount int64) {
	key := balanceKey(rlm.Previous().Address())
	store.Set(key, getInt(store, key)+amount)
}

func (impl) Withdraw(store *avl.Tree, rlm realm, amount int64) {
	user := rlm.Previous().Address()
	key := balanceKey(user)
	bal := getInt(store, key)
	if amount > bal {
		panic("v2: insufficient balance")
	}
	fee := amount / 100
	store.Set(key, bal-amount)
	if fee > 0 {
		store.Set(feesKey, getInt(store, feesKey)+fee)
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bnk.SendCoins(rlm.Address(), user, chain.Coins{chain.NewCoin("ugnot", amount-fee)})
}

func (impl) BalanceOf(store *avl.Tree, addr address) int64 {
	return getInt(store, balanceKey(addr))
}

func (impl) Render(store *avl.Tree, _ string) string {
	return ufmt.Sprintf("# Vault (v2)\n\nFees collected: %dugnot\n", getInt(store, feesKey))
}

// balanceKey must match v1's schema: v2 reads the balance v1 wrote.
func balanceKey(addr address) string {
	return "balance/" + addr.String()
}

func getInt(store *avl.Tree, key string) int64 {
	if v := store.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}