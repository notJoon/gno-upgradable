// PKGPATH: gno.land/r/demo/main

// An implementation with only typed methods needs Impl, not Dispatcher or
// Renderer. Upgrade installs only the value it saved, and the same realm
// returning to a value that served before is a rollback.
package main

import (
	"testing"

	"gno.land/p/upgrade/v0"
)

const (
	admin address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
	path          = "gno.land/r/demo/main"
)

var proxy *upgrade.Proxy

type Counter interface {
	upgrade.Impl
	Add(tx *upgrade.Tx)
	Value(v upgrade.View) int64
}

type v1 struct{}

func (v1) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from upgrade.ImplRef) {
	if from.Empty() {
		println("bootstrap from empty")
		return
	}
	if !from.Is(path, v2{}) {
		panic("v1: unexpected migration source")
	}
	println("v1 from v2")
}

func (v1) Add(tx *upgrade.Tx) {
	tx.Set("counter", "value", tx.View().GetInt64("counter", "value")+1)
}
func (v1) Value(v upgrade.View) int64 { return v.GetInt64("counter", "value") }

type v2 struct{ v1 }

func (v2) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from upgrade.ImplRef) {
	if !from.Is(path, v1{}) {
		panic("v2: unexpected migration source")
	}
	println("v2 from v1")
}

func (v2) Add(tx *upgrade.Tx) {
	tx.Set("counter", "value", tx.View().GetInt64("counter", "value")+2)
}

func init(cur realm) {
	proxy = upgrade.NewProxy(0, cur, admin, 1)
}

func approve(cur realm, path string)    { proxy.Approve(0, cur, path) }
func upgradeTo(cur realm, next Counter) { proxy.Upgrade(0, cur, next) }

func add(cur realm) {
	proxy.Invoke(0, cur, func(impl upgrade.Impl, tx *upgrade.Tx, _ *upgrade.Custody) {
		impl.(Counter).Add(tx)
	})
}

func value() (out int64) {
	proxy.Inspect(func(impl upgrade.Impl, v upgrade.View) {
		out = impl.(Counter).Value(v)
	})
	return out
}

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(admin))
	approve(cross(cur), path)
	testing.SetRealm(testing.NewCodeRealm(path))
	upgradeTo(cross(cur), v1{})

	testing.SetRealm(testing.NewUserRealm(admin))
	add(cross(cur))
	println(value())
	candidate := proxy.InspectImpl(v2{})
	println("typed candidate:", len(candidate.Calls), len(candidate.Queries), len(candidate.MissingCalls), len(candidate.MissingQueries))

	approve(cross(cur), path)
	print(proxy.Render(""))
	testing.SetRealm(testing.NewCodeRealm(path))
	upgradeTo(cross(cur), v2{})
	testing.SkipHeights(1)
	println(revive(func() { upgradeTo(cross(cur), v1{}) }))
	upgradeTo(cross(cur), v2{})

	testing.SetRealm(testing.NewUserRealm(admin))
	add(cross(cur))
	println(value())

	approve(cross(cur), path)
	testing.SetRealm(testing.NewCodeRealm(path))
	upgradeTo(cross(cur), v1{})
	print(proxy.Render(""))
	testing.SkipHeights(1)
	upgradeTo(cross(cur), v1{})

	testing.SetRealm(testing.NewUserRealm(admin))
	add(cross(cur))
	println(value())
}

// Output:
// bootstrap from empty
// 1
// typed candidate: 0 0 0 0
// > [!WARNING]
// > Upgrade approved: `gno.land/r/demo/main`. Its delay of 1 blocks starts when it calls Upgrade.
//
// upgrade: next is not the prepared implementation
// v2 from v1
// 3
// > [!WARNING]
// > Rollback pending: `gno.land/r/demo/main` can take over at block 125.
//
// v1 from v2
// 4
