// PKGPATH: gno.land/r/demo/main

// Every event the library emits names the proxy realm in a "realm"
// attribute, including the ones an implementation emits through tx.Emit.
// The event's pkg_path is the library's, shared by every proxy, so it
// cannot tell them apart.
package main

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/upgrade/vault"
	v1 "gno.land/r/upgrade/vault/v1"
	v2 "gno.land/r/upgrade/vault/v2"
)

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v1")
	v1.Bootstrap(cross(cur))

	testing.IssueCoins(chain.PackageAddress("gno.land/r/upgrade/vault"), chain.Coins{{"ugnot", 100}})
	testing.SetOriginSend(chain.Coins{{"ugnot", 100}})
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("alice")))
	vault.Call(cross(cur), "Deposit", "")
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(vault.Admin0))
	vault.Approve(cross(cur), "gno.land/r/upgrade/vault/v2")
	v2.Prepare(cross(cur))
	alice := testutils.TestAddress("alice")
	vault.TransferAdmin(cross(cur), alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	vault.AcceptAdmin(cross(cur))
}

// Events:
// [
//   {
//     "type": "UpgradeApproved",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "pkgPath",
//         "value": "gno.land/r/upgrade/vault/v1"
//       },
//       {
//         "key": "eta",
//         "value": "123"
//       },
//       {
//         "key": "rollback",
//         "value": "false"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "Upgraded",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "gno.land/r/upgrade/vault/v1"
//       },
//       {
//         "key": "rollback",
//         "value": "false"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "Deposit",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "caller",
//         "value": "g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh"
//       },
//       {
//         "key": "amount",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "UpgradeApproved",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "pkgPath",
//         "value": "gno.land/r/upgrade/vault/v2"
//       },
//       {
//         "key": "eta",
//         "value": "0"
//       },
//       {
//         "key": "rollback",
//         "value": "false"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "UpgradePrepared",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "pkgPath",
//         "value": "gno.land/r/upgrade/vault/v2"
//       },
//       {
//         "key": "eta",
//         "value": "17403"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "OwnershipTransferStarted",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "from",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "to",
//         "value": "g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   },
//   {
//     "type": "OwnershipTransferred",
//     "attrs": [
//       {
//         "key": "realm",
//         "value": "gno.land/r/upgrade/vault"
//       },
//       {
//         "key": "from",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "to",
//         "value": "g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh"
//       }
//     ],
//     "pkg_path": "gno.land/p/upgrade/v0"
//   }
// ]
