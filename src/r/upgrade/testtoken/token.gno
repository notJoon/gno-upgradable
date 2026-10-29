// Package testtoken provides two GRC20 tokens, A and B, with a faucet,
// for testing upgradable realms that hold tokens.
package testtoken

import (
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	A, B             *grc20.Token
	aLedger, bLedger *grc20.PrivateLedger
)

func init(cur realm) {
	var id seqid.ID
	A, aLedger = grc20.NewToken("Token A", "A", 0, id.Next(), cur)
	B, bLedger = grc20.NewToken("Token B", "B", 0, id.Next(), cur)
}

// Faucet mints amount of both tokens to the caller.
func Faucet(cur realm, amount int64) {
	to := cur.Previous().Address()
	must(aLedger.Mint(to, amount))
	must(bLedger.Mint(to, amount))
}

// Approve lets spender take up to amount of the caller's token symbol.
func Approve(cur realm, symbol string, spender address, amount int64) {
	ledger := aLedger
	if symbol == "B" {
		ledger = bLedger
	}
	must(ledger.CallerTeller().Approve(0, cur, spender, amount))
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}
