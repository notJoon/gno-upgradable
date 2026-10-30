// Package vault/v1 is the first implementation of
// gno.land/r/upgrade/vault. It keeps no state and no authority
// of its own. Its exported functions do nothing without the live
// Tx and Custody that only the vault can create, so later versions
// may build on them.
//
// Methods: Call("Deposit", ""), Call("Withdraw", "<amount>"),
// Query("BalanceOf", "<address>").
package vault

import (
	"chain"
	"strconv"

	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/vault"
)

const Balances = "balances" // address -> int64

// Upgrade installs v1 once the vault has approved this realm: at once as
// the first implementation, or in two calls around the delay, as when
// rolling back to v1.
func Upgrade(cur realm) { proxy.Upgrade(cross(cur), Impl{}) }

type Impl struct{}

var _ proxy.Implementation = Impl{}

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {}

func (Impl) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{
		{Name: "Deposit", Schema: "v1:void->void"},
		{Name: "Withdraw", Schema: "v1:int64->void"},
	}, []upgrade.Method{{Name: "BalanceOf", Schema: "v1:address->int64"}}
}

func (Impl) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	switch method {
	case "Deposit":
		Deposit(tx)
	case "Withdraw":
		amount := ParseAmount(args)
		Debit(tx, amount)
		c.Pay(tx.Caller(), chain.Coins{chain.NewCoin("ugnot", amount)})
		tx.Emit("Withdraw", "caller", tx.Caller().String(), "amount", args)
	default:
		panic("vault: unknown method " + method)
	}
	return ""
}

func (Impl) Query(v upgrade.View, method, args string) string {
	if method != "BalanceOf" {
		panic("vault: unknown query " + method)
	}
	return strconv.FormatInt(v.GetInt64(Balances, args), 10)
}

func (Impl) Render(v upgrade.View, _ string) string {
	return "# Vault\n"
}

// Deposit credits the caller with the ugnot sent with the call.
func Deposit(tx *upgrade.Tx) {
	sent := tx.Sent()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("vault: send only ugnot to deposit")
	}
	key := tx.Caller().String()
	tx.Set(Balances, key, tx.View().GetInt64(Balances, key)+sent[0].Amount)
	tx.Emit("Deposit", "caller", key, "amount", strconv.FormatInt(sent[0].Amount, 10))
}

// Debit takes amount from the caller's balance.
func Debit(tx *upgrade.Tx, amount int64) {
	key := tx.Caller().String()
	bal := tx.View().GetInt64(Balances, key)
	if amount > bal {
		panic("vault: insufficient balance")
	}
	tx.Set(Balances, key, bal-amount)
}

// ParseAmount parses a positive ugnot amount.
func ParseAmount(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		panic("vault: amount must be a positive integer")
	}
	return n
}
