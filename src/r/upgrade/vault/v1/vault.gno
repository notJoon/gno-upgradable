// Package vault/v1 is the first implementation of
// gno.land/r/upgrade/vault. It keeps no state and no authority
// of its own. Its exported functions do nothing without the live
// Tx and Custody that only the vault can create, so later versions
// may build on them.
package vault

import (
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/vault"
)

const Balances = "balances" // address -> int64

// Activate makes v1 the vault's implementation.
// It succeeds only while the vault has approved this realm.
func Activate(cur realm) {
	proxy.Register(cross(cur), Impl{})
}

type Impl struct{}

func (Impl) Deposit(tx *upgrade.Tx, amount int64) {
	key := tx.Caller().String()
	tx.Set(Balances, key, GetInt(tx.View(), Balances, key)+amount)
}

func (Impl) Withdraw(tx *upgrade.Tx, c *proxy.Custody, amount int64) {
	Debit(tx, amount)
	c.Pay(tx.Caller(), amount)
}

func (Impl) BalanceOf(v upgrade.View, addr address) int64 {
	return GetInt(v, Balances, addr.String())
}

func (Impl) Render(v upgrade.View, _ string) string {
	return "# Vault\n"
}

// Debit takes amount from the caller's balance.
func Debit(tx *upgrade.Tx, amount int64) {
	key := tx.Caller().String()
	bal := GetInt(tx.View(), Balances, key)
	if amount > bal {
		panic("vault: insufficient balance")
	}
	tx.Set(Balances, key, bal-amount)
}

func GetInt(v upgrade.View, table, key string) int64 {
	if n := v.Get(table, key); n != nil {
		return n.(int64)
	}
	return 0
}