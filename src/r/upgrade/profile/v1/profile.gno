// Package profile/v1 is the first implementation of
// gno.land/r/upgrade/profile.
package profile

import (
	pb "gno.land/p/notjoon/encoding/protobuf/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/profile"
)

// Profiles maps an address to a record:
//
//	message Profile {
//	  uint64 writer = 1; // the highest field number the last writer knew
//	  string name = 2;
//	}
const Profiles = "profiles"

// known is the highest field number this version writes.
const known = 2

const maxName = 64

func Upgrade(cur realm) { proxy.Upgrade(cross(cur), Impl{}) }

type Impl struct{}

var _ proxy.Profile = Impl{}

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from upgrade.ImplRef) {}

func (Impl) SetName(tx *upgrade.Tx, name string) {
	if len(name) > maxName {
		panic("profile: name too long")
	}
	key := tx.Caller().String()
	e := edit(tx.View(), key)
	e.String(2, name)
	tx.Set(Profiles, key, e.Encode())
}

func (Impl) Show(v upgrade.View, who address) string {
	return pb.Read(v.GetBytes(Profiles, who.String())).String(2)
}

// edit starts every write, so that field 1 always names this version.
// Fields a newer version added are kept as they are.
func edit(v upgrade.View, key string) *pb.Editor {
	e := pb.Read(v.GetBytes(Profiles, key)).Edit()
	e.Uint64(1, known)
	return e
}
