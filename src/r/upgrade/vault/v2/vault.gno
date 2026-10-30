// Package vault (v2) is the second implementation of
// gno.land/r/upgrade/vault. It reuses v1, adds a 1% withdrawal fee and a
// CollectFees method for the admin. The fee total lives in a table v1 never
// had. The vault itself did not change.
package vault

import (
	"chain"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

const Fees = "fees" // total -> int64

// Prepare starts the delay once the vault has approved this realm.
func Prepare(cur realm) {
	proxy.Prepare(cross(cur), impl{})
}

// Activate makes v2 the vault's implementation. It succeeds only
// while the vault has approved this realm.
func Activate(cur realm) {
	proxy.Register(cross(cur))
}

// impl inherits every method it does not handle from v1, including
// Migrate, which accepts any predecessor so that a rollback to v2 from a
// later version works.
type impl struct {
	v1.Impl
}

func (impl) ID() string { return "gno.land/r/upgrade/vault/v2:impl" }

func (i impl) Methods() (calls, queries []upgrade.Method) {
	calls, queries = i.Impl.Methods()
	return append(calls, upgrade.Method{Name: "CollectFees", Schema: "v1:void->void"}), queries
}

func (i impl) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	switch method {
	case "Withdraw":
		amount := v1.ParseAmount(args)
		v1.Debit(tx, amount)
		fee := amount / 100
		if fee > 0 {
			tx.Set(Fees, "total", tx.View().GetInt64(Fees, "total")+fee)
		}
		c.Pay(tx.Caller(), chain.Coins{chain.NewCoin("ugnot", amount-fee)})
		tx.Emit("Withdraw", "caller", tx.Caller().String(), "amount", args, "fee", strconv.FormatInt(fee, 10))
		return ""
	case "CollectFees":
		if tx.Caller() != proxy.Admin() {
			panic("vault: only the admin collects fees")
		}
		total := tx.View().GetInt64(Fees, "total")
		if total > 0 {
			tx.Set(Fees, "total", int64(0))
			c.Pay(tx.Caller(), chain.Coins{chain.NewCoin("ugnot", total)})
		}
		return ""
	}
	// v1's Call only reaches v1's methods, so any method v2 overrides
	// must be handled above.
	return i.Impl.Call(tx, c, method, args)
}

func (impl) Render(v upgrade.View, _ string) string {
	return ufmt.Sprintf("# Vault\n\nFees collected: %dugnot\n", v.GetInt64(Fees, "total"))
}
