// Package counter is the smallest upgradable realm: a per-address counter
// with typed entry points. Its implementations only provide upgrade.Impl and
// the Counter methods, with no method lists, schemas or string arguments.
package counter

import (
	"gno.land/p/upgrade/v0"
)

// UpgradeDelay is how many blocks pass between an approved realm's first
// Upgrade call and the call that installs it, about a day at 5s blocks.
const UpgradeDelay = 17280

const Admin0 address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

var proxy *upgrade.Proxy

// Counter is what every implementation provides. One may also implement
// upgrade.Renderer to add its own view below the proxy's banner.
type Counter interface {
	upgrade.Impl
	Inc(tx *upgrade.Tx)
	Get(v upgrade.View, who address) int64
}

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, Admin0, UpgradeDelay)
}

// Inc adds to the caller's count.
func Inc(cur realm) {
	proxy.Invoke(0, cur, func(impl upgrade.Impl, tx *upgrade.Tx, _ *upgrade.Custody) {
		impl.(Counter).Inc(tx)
	})
}

// Get returns the count of who.
func Get(who address) (n int64) {
	proxy.Inspect(func(impl upgrade.Impl, v upgrade.View) {
		n = impl.(Counter).Get(v, who)
	})
	return n
}

func Approve(cur realm, pkgPath string)         { proxy.Approve(0, cur, pkgPath) }
func Cancel(cur realm)                          { proxy.Cancel(0, cur) }
func Freeze(cur realm)                          { proxy.Freeze(0, cur) }
func TransferAdmin(cur realm, newAdmin address) { proxy.TransferOwnership(0, cur, newAdmin) }
func AcceptAdmin(cur realm)                     { proxy.AcceptOwnership(0, cur) }

// Upgrade is called by the approved implementation realm: once to start the
// delay after its code is deployed, and again after it to install next.
// The first implementation installs on the first call.
func Upgrade(cur realm, next Counter) { proxy.Upgrade(0, cur, next) }

func Admin() address   { return proxy.Owner() }
func ImplPath() string { return proxy.ImplPath() }
func Approved() string { return proxy.Approved() }

// ApprovedETA returns the first block height at which the approved realm can
// install, or 0 until its first Upgrade call starts the delay.
func ApprovedETA() int64 { return proxy.ETA() }

func Render(path string) string { return proxy.Render(path) }
