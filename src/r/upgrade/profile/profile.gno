// Package profile keeps one record per address, encoded as a protobuf
// message with gno.land/p/notjoon/encoding/protobuf. Its v2 adds a field to
// the record, and rolling back to v1 keeps that field. See
// docs/record-format.md for the conventions the implementations follow.
package profile

import (
	"gno.land/p/upgrade/v0"
)

// UpgradeDelay is how many blocks pass between an approved realm's first
// Upgrade call and the call that installs it, about a day at 5s blocks.
const UpgradeDelay = 17280

// UpgradeWindow is how many blocks after the delay the approved realm has to
// install. Past it, the admin must approve again and the delay restarts.
const UpgradeWindow = 17280

const Admin0 address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

var proxy *upgrade.Proxy

// Profile is what every implementation provides.
type Profile interface {
	upgrade.Impl
	SetName(tx *upgrade.Tx, name string)
	Show(v upgrade.View, who address) string
}

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, Admin0, UpgradeDelay, UpgradeWindow)
}

// SetName sets the caller's name.
func SetName(cur realm, name string) {
	proxy.Invoke(0, cur, func(impl upgrade.Impl, tx *upgrade.Tx, _ *upgrade.Custody) {
		impl.(Profile).SetName(tx, name)
	})
}

// Show describes the profile of who.
func Show(who address) (s string) {
	proxy.Inspect(func(impl upgrade.Impl, v upgrade.View) {
		s = impl.(Profile).Show(v, who)
	})
	return s
}

func Approve(cur realm, pkgPath string)         { proxy.Approve(0, cur, pkgPath) }
func Cancel(cur realm)                          { proxy.Cancel(0, cur) }
func Freeze(cur realm)                          { proxy.Freeze(0, cur) }
func TransferAdmin(cur realm, newAdmin address) { proxy.TransferOwnership(0, cur, newAdmin) }
func AcceptAdmin(cur realm)                     { proxy.AcceptOwnership(0, cur) }

// Upgrade is called by the approved implementation realm: once to start the
// delay after its code is deployed, and again after it to install next.
// The first implementation installs on the first call.
func Upgrade(cur realm, next Profile) { proxy.Upgrade(0, cur, next) }

func Admin() address   { return proxy.Owner() }
func ImplPath() string { return proxy.ImplPath() }

func Render(path string) string { return proxy.Render(path) }
