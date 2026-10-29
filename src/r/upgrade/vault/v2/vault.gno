// Package vault (v2) is the second implementation of
// gno.land/r/demo/upgrade/vault. It reuses v1 and adds a 1% withdrawal
// fee. The fee total lives in a table v1 never had. The vault itself did
// not change.
package vault

import (
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)


const Fees = "fees" // total -> int64

// Activate makes v2 the vault's implementation. It succeeds only
// while the vault has approved this realm.
func Activate(cur realm) {
	proxy.Register(cross(cur), impl{})
}

// impl Inherits every operation it does not override from v1.
type impl struct{
	v1.Impl
}

func (impl) Withdraw(tx *upgrade.Tx, c *proxy.Custody, amount int64) {
	v1.Debit(tx, amount)
	fee := amount / 100
	if fee > 0 {
		tx.Set(Fees, "total", v1.GetInt(tx.View(), Fees, "total")+fee)
	}
	c.Pay(tx.Caller(), amount-fee)
}

func (impl) Render(v upgrade.View, _ string) string {
	return ufmt.Sprintf("# Vault\n\nFees collected: %dugnot\n", v1.GetInt(v, Fees, "total"))
}