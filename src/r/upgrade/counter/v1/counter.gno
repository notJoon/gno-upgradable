// Package counter/v1 is the first implementation of
// gno.land/r/upgrade/counter. It has no Render, so the proxy shows only its
// upgrade banner.
package counter

import (
	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/counter"
)

const Counts = "counts" // address -> int64

func Bootstrap(cur realm) { proxy.Bootstrap(cross(cur), Impl{}) }
func Prepare(cur realm)   { proxy.Prepare(cross(cur), Impl{}) }
func Activate(cur realm)  { proxy.Register(cross(cur)) }

type Impl struct{}

func (Impl) ID() string { return "gno.land/r/upgrade/counter/v1:impl" }

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {}

func (Impl) Inc(tx *upgrade.Tx) {
	key := tx.Caller().String()
	tx.Set(Counts, key, tx.View().GetInt64(Counts, key)+1)
}

func (Impl) Get(v upgrade.View, who address) int64 {
	return v.GetInt64(Counts, who.String())
}
