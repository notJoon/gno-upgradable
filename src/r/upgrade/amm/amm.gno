// Package amm is an upgradable constant-product pool. It holds the tokens
// and the state, and forwards to the implementation the admin approved.
//
// Methods that take only strings go through Call and Query and are defined
// by the implementation. Swap takes a callback and Reserves returns typed
// values, so they are fixed typed functions here, served through the Pool
// interface every implementation must satisfy.
package amm

import (
	"gno.land/p/upgrade/v0"
)

// UpgradeDelay is how many blocks an approved upgrade waits before it can
// be activated, about a day at 5s blocks.
const UpgradeDelay = 17280

// Admin0 is the first admin, who approves upgrades. It is written in the
// source, not taken from the deployer, so anyone reviewing the realm can see
// who controls it. TransferAdmin moves the role later, so implementations
// must check Admin(), never Admin0.
const Admin0 address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

// Pool combines the optional upgrade capabilities with the typed entry points
// Call cannot carry. Changing it means a new proxy, so it holds only what must
// be typed.
type Pool interface {
	upgrade.Dispatcher
	upgrade.Renderer

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
	proxy  *upgrade.Proxy
	locked bool
)

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, Admin0, UpgradeDelay)
}

// Prepare is called by the approved implementation realm to start the
// delay, once its code is deployed.
func Prepare(cur realm, next Pool) {
	defer guard()()
	proxy.Prepare(0, cur, next)
}

// Bootstrap installs the first approved implementation without a delay.
func Bootstrap(cur realm, first Pool) {
	defer guard()()
	proxy.Bootstrap(0, cur, first)
}

// Register activates the Pool saved by Prepare.
func Register(cur realm) {
	defer guard()()
	proxy.Register(0, cur)
}

// Swap swaps amountIn of token0 for token1 (or the reverse), sending the
// output to `to`, and collects payment through cb.
func Swap(cur realm, zeroForOne bool, amountIn, minOut int64, to address, cb SwapCallback) (out int64) {
	if cb == nil {
		panic("amm: nil callback")
	}
	defer guard()()
	proxy.Invoke(0, cur, func(impl upgrade.Impl, tx *upgrade.Tx, c *upgrade.Custody) {
		pay := func(owed int64) { cb(cross(cur), owed, &CallbackMarker{}) }
		out = impl.(Pool).Swap(tx, c, zeroForOne, amountIn, minOut, to, pay)
	})
	return out
}

func Reserves() (r0, r1 int64) {
	assertUnlocked()
	proxy.Inspect(func(impl upgrade.Impl, v upgrade.View) {
		r0, r1 = impl.(Pool).Reserves(v)
	})
	return r0, r1
}

func Call(cur realm, method, args string) string {
	defer guard()()
	return proxy.Call(0, cur, method, args)
}

func Query(method, args string) string {
	assertUnlocked()
	return proxy.Query(method, args)
}

func Render(path string) string {
	assertUnlocked()
	return proxy.Render(path)
}

// Approve lets pkgPath register after the delay. Unless it served before,
// it must answer every method in API.
func Approve(cur realm, pkgPath string) {
	defer guard()()
	proxy.Approve(0, cur, pkgPath)
}

func Cancel(cur realm) {
	defer guard()()
	proxy.Cancel(0, cur)
}

// Freeze ends upgrades for good. The current implementation keeps serving.
func Freeze(cur realm) {
	defer guard()()
	proxy.Freeze(0, cur)
}

func TransferAdmin(cur realm, newAdmin address) {
	defer guard()()
	proxy.TransferOwnership(0, cur, newAdmin)
}

func AcceptAdmin(cur realm) {
	defer guard()()
	proxy.AcceptOwnership(0, cur)
}

func Admin() address        { return proxy.Owner() }
func PendingAdmin() address { return proxy.PendingOwner() }
func Frozen() bool          { return proxy.Frozen() }
func ImplPath() string      { return proxy.ImplPath() }
func Approved() string      { return proxy.Approved() }
func ApprovedETA() int64    { return proxy.ETA() }

// Methods lists the methods Call and Query answer now.
func Methods() (calls, queries []upgrade.Method) {
	assertUnlocked()
	return proxy.Methods()
}

// API lists every method any implementation has served. After a rollback
// some may be unavailable; a later implementation must answer them all.
func API() (calls, queries []upgrade.Method) {
	assertUnlocked()
	return proxy.API()
}

// Missing lists the API methods next lacks, so an implementation's tests
// can check it before approval.
func Missing(next upgrade.Dispatcher) (calls, queries []upgrade.Method) {
	assertUnlocked()
	return proxy.Missing(next)
}

func ImplID() string              { return proxy.ImplID() }
func PendingImplID() string       { return proxy.PendingImplID() }
func ManifestHash() string        { return proxy.ManifestHash() }
func PendingManifestHash() string { return proxy.PendingManifestHash() }

func guard() func() {
	assertUnlocked()
	locked = true
	return func() { locked = false }
}

func assertUnlocked() {
	if locked {
		panic(upgrade.ErrReentrant)
	}
}
