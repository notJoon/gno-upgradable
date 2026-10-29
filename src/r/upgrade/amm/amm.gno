// Package amm is an upgradable constant-product pool. It holds the tokens
// and the state, and forwards to the implementation the admin approved.
//
// Methods that take only strings go through Call and Query and are defined
// by the implementation. Swap takes a callback and Reserves returns typed
// values, so they are fixed typed functions here, served through the Pool
// interface every implementation must satisfy.
package amm

import (
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/upgrade/v0"
)

// UpgradeDelay is how many blocks an approved upgrade waits before it can
// be activated, about a day at 5s blocks.
const UpgradeDelay = 17280

// Pool is what an implementation provides beyond upgrade.Impl: the typed
// entry points Call cannot carry. Changing it means a new proxy, so it holds
// only what must be typed.
type Pool interface {
	upgrade.Impl

	// Swap sends the output to `to`, then calls pay with the amount owed,
	// and must check the pool's balance rose by at least that much.
	Swap(tx *upgrade.Tx, c *upgrade.Custody, zeroForOne bool, amountIn, minOut int64, to address, pay func(owed int64)) int64
	Reserves(v upgrade.View) (r0, r1 int64)
}

// SwapCallback pays what a swap owes. It is called with the pool as its
// caller. CallbackMarker can only be built here, so no existing crossing
// function, such as a token's Transfer, can be passed in as a callback and
// run with the pool as its caller.
type SwapCallback func(cur realm, owed int64, m *CallbackMarker)

type CallbackMarker struct{}

var (
	admin  = ownable.NewWithAddress("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	proxy  *upgrade.Proxy
	locked bool
)

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, UpgradeDelay, "gno.land/r/upgrade/amm/v1")
}

// Register is called by the approved implementation realm to take over.
// Taking a Pool makes the compiler check the typed entry points.
func Register(cur realm, next Pool) {
	proxy.Register(0, cur, next)
}

// Swap swaps amountIn of token0 for token1 (or the reverse), sending the
// output to `to`, and collects payment through cb.
func Swap(cur realm, zeroForOne bool, amountIn, minOut int64, to address, cb SwapCallback) (out int64) {
	if cb == nil {
		panic("amm: nil callback")
	}
	defer enter()()
	proxy.Invoke(0, cur, func(impl upgrade.Impl, tx *upgrade.Tx, c *upgrade.Custody) {
		pay := func(owed int64) { cb(cross(cur), owed, &CallbackMarker{}) }
		out = impl.(Pool).Swap(tx, c, zeroForOne, amountIn, minOut, to, pay)
	})
	return out
}

func Reserves() (r0, r1 int64) {
	impl, v := proxy.Current()
	return impl.(Pool).Reserves(v)
}

func Call(cur realm, method, args string) string {
	defer enter()()
	return proxy.Call(0, cur, method, args)
}

func Query(method, args string) string { return proxy.Query(method, args) }

func Render(path string) string { return proxy.Render(path) }

// enter refuses a call made while another is running, such as one from a
// swap callback, which would see the pool mid-swap. It returns the unlock.
func enter() func() {
	if locked {
		panic("amm: reentrant call")
	}
	locked = true
	return func() { locked = false }
}

func Approve(cur realm, pkgPath string) {
	admin.AssertOwnedBy(cur.Previous().Address())
	proxy.Approve(pkgPath)
}

func Cancel(cur realm) {
	admin.AssertOwnedBy(cur.Previous().Address())
	proxy.Cancel()
}

func TransferAdmin(cur realm, newAdmin address) {
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err)
	}
}

func Admin() address     { return admin.Owner() }
func ImplPath() string   { return proxy.ImplPath() }
func Approved() string   { return proxy.Approved() }
func ApprovedETA() int64 { return proxy.ETA() }
