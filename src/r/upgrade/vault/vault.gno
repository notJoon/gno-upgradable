// Package vault is an upgradable ugnot vault. It holds the coins and the
// state, and forwards every call to the implementation realm the admin
// approved, so its address and API never change across versions.
//
// Users call Call(method, args) and read with Query(method, args). The
// methods are whatever the current implementation provides.
package vault

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

var proxy *upgrade.Proxy

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, Admin0, UpgradeDelay)
}

// Approve lets pkgPath register after the delay. Unless it served before,
// it must answer every method in API.
func Approve(cur realm, pkgPath string) { proxy.Approve(0, cur, pkgPath) }

// Cancel drops the pending approval.
func Cancel(cur realm) { proxy.Cancel(0, cur) }

// Freeze ends upgrades for good. The current implementation keeps serving.
func Freeze(cur realm) { proxy.Freeze(0, cur) }

func TransferAdmin(cur realm, newAdmin address) { proxy.TransferOwnership(0, cur, newAdmin) }

func AcceptAdmin(cur realm) { proxy.AcceptOwnership(0, cur) }

// Admin returns the address that approves upgrades. Implementations use it
// to gate admin methods.
func Admin() address { return proxy.Owner() }

func PendingAdmin() address { return proxy.PendingOwner() }

func Frozen() bool { return proxy.Frozen() }

// Prepare is called by the approved implementation realm to start the
// delay, once its code is deployed.
func Prepare(cur realm, next upgrade.Impl) {
	proxy.Prepare(0, cur, next)
}

// Bootstrap installs the first approved implementation without a delay.
func Bootstrap(cur realm, first upgrade.Impl) {
	proxy.Bootstrap(0, cur, first)
}

// Register activates the implementation saved by Prepare.
func Register(cur realm) {
	proxy.Register(0, cur)
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

// Methods lists the methods Call and Query answer now.
func Methods() (calls, queries []string) { return proxy.Methods() }

// API lists every method any implementation has served. After a rollback
// some may be unavailable; a later implementation must answer them all.
func API() (calls, queries []string) { return proxy.API() }

// Missing lists the API methods next lacks, so an implementation's tests
// can check it before approval.
func Missing(next upgrade.Impl) (calls, queries []string) { return proxy.Missing(next) }

func Render(path string) string { return proxy.Render(path) }
