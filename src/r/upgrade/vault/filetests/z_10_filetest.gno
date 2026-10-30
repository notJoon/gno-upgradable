// PKGPATH: gno.land/r/demo/main

// An implementation cannot persist the proxy's write handles for use after
// the crossing call returns.
package main

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/upgrade/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
)

type handles struct {
	tx *upgrade.Tx
	c  *upgrade.Custody
}

var kept *handles

type sticky struct{ v1.Impl }


func (sticky) Call(tx *upgrade.Tx, c *upgrade.Custody, method, args string) string {
	kept = &handles{tx: tx, c: c}
	return ""
}

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Upgrade(cross(cur))
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/demo/main")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/main"))
	vault.Upgrade(cross(cur), sticky{})
	testing.SkipHeights(vault.UpgradeDelay)
	vault.Upgrade(cross(cur), sticky{})
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("alice")))
	vault.Call(cross(cur), "Deposit", "")
}

// Error:
// cannot persist realm value: realm values are ephemeral and tied to a call frame
