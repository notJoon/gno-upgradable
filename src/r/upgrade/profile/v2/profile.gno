// Package profile/v2 adds the height of the last change to each record.
// It needs no migration: a record v1 wrote simply lacks the new field.
package profile

import (
	"chain/runtime"
	"strconv"

	pb "gno.land/p/notjoon/encoding/protobuf/v0"
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/profile"
)

// Profiles maps an address to a record:
//
//	message Profile {
//	  uint64 writer = 1; // the highest field number the last writer knew
//	  string name = 2;
//	  sint64 updated = 3; // height of the last SetName, added by v2
//	}
const Profiles = "profiles"

// known is the highest field number this version writes.
const known = 3

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
	e.Sint64(3, runtime.ChainHeight())
	tx.Set(Profiles, key, e.Encode())
}

// Show reports the height of the last change. After a rollback, v1 may
// have changed the name without updating that height, which field 1
// reveals. The kept height is then only a lower bound.
func (Impl) Show(v upgrade.View, who address) string {
	m := pb.Read(v.GetBytes(Profiles, who.String()))
	name := m.String(2)
	switch {
	case !m.Has(3):
		return name
	case m.Uint64(1) < 3:
		return name + ", changed after block " + strconv.FormatInt(m.Sint64(3), 10)
	default:
		return name + ", changed at block " + strconv.FormatInt(m.Sint64(3), 10)
	}
}

// edit starts every write, so that field 1 always names this version.
func edit(v upgrade.View, key string) *pb.Editor {
	e := pb.Read(v.GetBytes(Profiles, key)).Edit()
	e.Uint64(1, known)
	return e
}
