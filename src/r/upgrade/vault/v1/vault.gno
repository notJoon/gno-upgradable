package vault

import (
	"chain"
	"chain/banker"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	proxy "gno.land/r/upgrade/vault"
)

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
		panic("v1: insufficient balance")
	}
	store.Set(key, bal-amount)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bnk.SendCoins(rlm.Address(), user, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func (impl) BalanceOf(store *avl.Tree, addr address) int64 {
	return getInt(store, balanceKey(addr))
}

func (impl) Render(store *avl.Tree, _ string) string {
	return ufmt.Sprintf("# Vault (v1)\n\nAccounts: %d\n", store.Size())
}

func balanceKey(addr address) string {
	return "balance/" + addr.String()
}

func getInt(store *avl.Tree, key string) int64 {
	if v := store.Get(key); v != nil {
		return v.(int64)
	}
	return 0
}