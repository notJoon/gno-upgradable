// PKGPATH: gno.land/r/demo/main

// An implementation cannot store a pointer it allocated, so once replaced
// it keeps no write access to the vault's state. The admin can also cancel
// a pending approval.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

const admin address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

type box struct{ N int64 }

// sticky tries to keep a handle on a row it wrote.
type sticky struct{ v1.Impl }

func (sticky) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {
	println("migrate from:", from)
}

func (sticky) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	tx.Set("box", "k", &box{N: tx.Sent().AmountOf("ugnot")})
	return ""
}

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	v1.Bootstrap(cross(cur))

	testing.SetRealm(testing.NewUserRealm(admin))
	vault.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	vault.Prepare(cross(cur), sticky{})
	println("eta set:", vault.ApprovedETA() > 0)
	testing.SetRealm(testing.NewUserRealm(admin))
	vault.Cancel(cross(cur))
	println("after cancel:", vault.Approved() == "", vault.ApprovedETA())

	vault.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	vault.Prepare(cross(cur), sticky{})
	testing.SkipHeights(vault.UpgradeDelay)
	vault.Register(cross(cur))

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", 10}})
	println(revive(func() { vault.Call(cross(cur), "Deposit", "") }))
}

// Output:
// eta set: true
// after cancel: true 0
// migrate from: gno.land/r/upgrade/vault/v1
// upgrade: value must be string, bool, int64, uint64, address or []byte
