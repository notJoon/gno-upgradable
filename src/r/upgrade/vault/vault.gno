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

// UpgradeDelay is how many blocks pass between an approved realm's first
// Upgrade call and the call that installs it, about a day at 5s blocks.
const UpgradeDelay = 17280

// Admin0 is the first admin, who approves upgrades. It is written in the
// source, not taken from the deployer, so anyone reviewing the realm can see
// who controls it. TransferAdmin moves the role later, so implementations
// must check Admin(), never Admin0.
const Admin0 address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

var proxy *upgrade.Proxy

type Implementation interface {
	upgrade.Dispatcher
	upgrade.Renderer
}

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, Admin0, UpgradeDelay)
}

// Approve lets the realm at pkgPath upgrade. Unless that realm installed the
// same value before, the value must answer every method in API.
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

// Upgrade is called by the approved implementation realm: once to start the
// delay after its code is deployed, and again after it to install next.
// The first implementation installs on the first call.
func Upgrade(cur realm, next Implementation) { proxy.Upgrade(0, cur, next) }

func Call(cur realm, method, args string) string {
	return proxy.Call(0, cur, method, args)
}

func Query(method, args string) string { return proxy.Query(method, args) }

func ImplPath() string { return proxy.ImplPath() }

// Approved returns the approved implementation path, if any.
func Approved() string { return proxy.Approved() }

// ApprovedETA returns the first block height at which the approved realm can
// install, or 0 until its first Upgrade call starts the delay.
func ApprovedETA() int64 { return proxy.ETA() }

// Methods lists the methods Call and Query answer now.
func Methods() (calls, queries []upgrade.Method) { return proxy.Methods() }

// API lists every method any implementation has served. After a rollback
// some may be unavailable. A later implementation must answer them all.
func API() (calls, queries []upgrade.Method) { return proxy.API() }

// Missing lists the API methods next lacks, so an implementation's tests
// can check it before approval.
func Missing(next upgrade.Dispatcher) (calls, queries []upgrade.Method) { return proxy.Missing(next) }

func Render(path string) string { return proxy.Render(path) }
