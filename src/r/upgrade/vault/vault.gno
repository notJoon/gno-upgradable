// Package vault is an upgradable ugnot vault. It holds the coins and the
// state, and forwards every call to the implementation realm the admin
// approved, so its address and API never change across versions.
//
// Users call Call(method, args) and read with Query(method, args). The
// methods are whatever the current implementation provides.
package vault

import (
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/upgrade/v0"
)

// UpgradeDelay is how many blocks an approved upgrade waits before it can
// be activated, about a day at 5s blocks.
const UpgradeDelay = 17280

var (
	admin = ownable.NewWithAddress("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	proxy *upgrade.Proxy
)

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, UpgradeDelay, "gno.land/r/upgrade/vault/v1")
}

func Approve(cur realm, pkgPath string) {
	admin.AssertOwnedBy(cur.Previous().Address())
	proxy.Approve(pkgPath)
}

// Cancel drops the pending approval.
func Cancel(cur realm) {
	admin.AssertOwnedBy(cur.Previous().Address())
	proxy.Cancel()
}

func TransferAdmin(cur realm, newAdmin address) {
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err)
	}
}

// Admin returns the address that approves upgrades. Implementations use it
// to gate admin methods.
func Admin() address { return admin.Owner() }

// Register is called by the approved implementation realm to take over.
func Register(cur realm, next upgrade.Impl) {
	proxy.Register(0, cur, next)
}

func Call(cur realm, method, args string) string {
	return proxy.Call(0, cur, method, args)
}

func Query(method, args string) string { return proxy.Query(method, args) }

func ImplPath() string { return proxy.ImplPath() }

// Approved returns the implementation path waiting to register,
// if any.
func Approved() string { return proxy.Approved() }

// ApprovedETA returns the first block height at which the approved
// implementation can register, or 0 if there is none.
func ApprovedETA() int64 { return proxy.ETA() }

func Render(path string) string { return proxy.Render(path) }
