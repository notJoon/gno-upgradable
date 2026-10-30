// Package amm/v1 is the first implementation of gno.land/r/upgrade/amm: a
// constant-product pool of testtoken A and B with a 0.3% fee.
//
// Methods: Call("AddLiquidity", "<amountA> <amountB>") pulls both tokens from
// the caller, who must have approved the pool, and returns the shares
// minted. Query("SharesOf", "<address>").
package amm

import (
	"strconv"
	"strings"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/amm"
	"gno.land/r/upgrade/testtoken"
)

const (
	State  = "pool"   // "r0", "r1", "total" -> int64
	Shares = "shares" // address -> int64
)

// Prepare starts the delay once the pool has approved this realm.
func Prepare(cur realm) {
	proxy.Prepare(cross(cur), Impl{})
}

func Activate(cur realm) {
	proxy.Register(cross(cur), Impl{})
}

type Impl struct{}

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {}

func (Impl) Methods() (calls, queries []string) {
	return []string{"AddLiquidity"}, []string{"SharesOf"}
}

func (Impl) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	if method != "AddLiquidity" {
		panic("amm: unknown method " + method)
	}
	f := strings.Fields(args)
	if len(f) != 2 {
		panic("amm: want <amountA> <amountB>")
	}
	a0, a1 := parseAmount(f[0]), parseAmount(f[1])
	caller := tx.Caller()
	c.TransferFrom(testtoken.A, caller, c.Address(), a0)
	c.TransferFrom(testtoken.B, caller, c.Address(), a1)

	v := tx.View()
	r0, total := v.GetInt64(State, "r0"), v.GetInt64(State, "total")
	// shares follow token A only and a1 is taken as given. A real
	// pool would require the current ratio.
	minted := a0
	if total > 0 {
		minted = a0 * total / r0
	}
	tx.Set(State, "r0", r0+a0)
	tx.Set(State, "r1", v.GetInt64(State, "r1")+a1)
	tx.Set(State, "total", total+minted)
	key := caller.String()
	tx.Set(Shares, key, v.GetInt64(Shares, key)+minted)
	return strconv.FormatInt(minted, 10)
}

func (Impl) Query(v upgrade.View, method, args string) string {
	if method != "SharesOf" {
		panic("amm: unknown query " + method)
	}
	return strconv.FormatInt(v.GetInt64(Shares, args), 10)
}

func (Impl) Render(v upgrade.View, _ string) string {
	return "# AMM\n"
}

func (Impl) Reserves(v upgrade.View) (int64, int64) {
	return v.GetInt64(State, "r0"), v.GetInt64(State, "r1")
}

func (Impl) Swap(tx *upgrade.Tx, c *upgrade.Custody, zeroForOne bool, amountIn, minOut int64, to address, pay func(owed int64)) int64 {
	if amountIn <= 0 {
		panic("amm: amountIn must be positive")
	}
	inTok, outTok, inKey, outKey := testtoken.A, testtoken.B, "r0", "r1"
	if !zeroForOne {
		inTok, outTok, inKey, outKey = outTok, inTok, outKey, inKey
	}
	v := tx.View()
	rIn, rOut := v.GetInt64(State, inKey), v.GetInt64(State, outKey)
	// TODO: use uint256 package.
	out := amountIn * 997 * rOut / (rIn*1000 + amountIn*997)
	if out <= 0 || out < minOut {
		panic("amm: output below minimum")
	}

	c.Transfer(outTok, to, out)
	before := balance(inTok, c)
	pay(amountIn)
	if balance(inTok, c)-before < amountIn {
		panic("amm: callback underpaid")
	}

	tx.Set(State, inKey, rIn+amountIn)
	tx.Set(State, outKey, rOut-out)
	return out
}

func balance(tok *grc20.Token, c *upgrade.Custody) int64 {
	return tok.BalanceOf(c.Address())
}

func parseAmount(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		panic("amm: amount must be a positive integer")
	}
	return n
}
