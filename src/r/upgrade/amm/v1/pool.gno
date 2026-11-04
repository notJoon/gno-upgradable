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
	pb "gno.land/p/notjoon/encoding/protobuf/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/amm"
	"gno.land/r/upgrade/testtoken"
)

const (
	State  = "pool"   // "pool" -> the Pool record below
	Shares = "shares" // address -> int64
)

// The pool's reserves and share supply change together, so they are one
// record at State/"pool":
//
//	message Pool {
//	  uint64 writer = 1; // the highest field number the last writer knew
//	  sint64 r0 = 2;     // reserve of token A
//	  sint64 r1 = 3;     // reserve of token B
//	  sint64 total = 4;  // shares minted
//	}
const (
	poolKey = "pool"
	r0, r1  = 2, 3
	total   = 4
	known   = 4 // the highest field number this version writes
)

// Upgrade installs v1 once the pool has approved this realm: at once as the
// first implementation, or in two calls around the delay.
func Upgrade(cur realm) { proxy.Upgrade(cross(cur), Impl{}) }

type Impl struct{}

var _ proxy.Pool = Impl{}

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from upgrade.ImplRef) {}

func (Impl) Methods() (calls, queries []upgrade.Method) {
	return []upgrade.Method{{Name: "AddLiquidity", Schema: "v1:int64,int64->int64"}},
		[]upgrade.Method{{Name: "SharesOf", Schema: "v1:address->int64"}}
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
	p := pool(v)
	reserve0, supply := p.Sint64(r0), p.Sint64(total)
	// shares follow token A only and a1 is taken as given. A real
	// pool would require the current ratio.
	minted := a0
	if supply > 0 {
		minted = a0 * supply / reserve0
	}
	e := edit(p)
	e.Sint64(r0, reserve0+a0)
	e.Sint64(r1, p.Sint64(r1)+a1)
	e.Sint64(total, supply+minted)
	tx.Set(State, poolKey, e.Encode())
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
	p := pool(v)
	return p.Sint64(r0), p.Sint64(r1)
}

func (Impl) Swap(tx *upgrade.Tx, c *upgrade.Custody, zeroForOne bool, amountIn, minOut int64, to address, pay func(owed int64)) int64 {
	if amountIn <= 0 {
		panic("amm: amountIn must be positive")
	}
	inTok, outTok, inField, outField := testtoken.A, testtoken.B, pb.Number(r0), pb.Number(r1)
	if !zeroForOne {
		inTok, outTok, inField, outField = outTok, inTok, outField, inField
	}
	p := pool(tx.View())
	rIn, rOut := p.Sint64(inField), p.Sint64(outField)
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

	e := edit(p)
	e.Sint64(inField, rIn+amountIn)
	e.Sint64(outField, rOut-out)
	tx.Set(State, poolKey, e.Encode())
	return out
}

func pool(v upgrade.View) pb.Message { return pb.Read(v.GetBytes(State, poolKey)) }

// edit starts every write to the pool record, so that field 1 always names
// this version.
func edit(p pb.Message) *pb.Editor {
	e := p.Edit()
	e.Uint64(1, known)
	return e
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
