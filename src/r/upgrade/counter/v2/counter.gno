// Package counter/v2 keeps v1's counts, adds a running total and a Render.
// Its Migrate fills the total from the rows v1 wrote.
package counter

import (
	"strconv"

	"gno.land/p/upgrade/v0"
	proxy "gno.land/r/upgrade/counter"
	v1 "gno.land/r/upgrade/counter/v1"
)

const (
	Totals = "totals" // "all" -> int64
	all    = "all"
)

func Upgrade(cur realm) { proxy.Upgrade(cross(cur), Impl{}) }

type Impl struct{ v1.Impl }

var _ proxy.Counter = Impl{}

func (Impl) Migrate(tx *upgrade.Tx, c *upgrade.Custody, from string) {
	var total int64
	tx.View().Iterate(v1.Counts, "", "", func(_ string, value any) bool {
		total += value.(int64)
		return false
	})
	tx.Set(Totals, all, total)
}

func (i Impl) Inc(tx *upgrade.Tx) {
	i.Impl.Inc(tx)
	tx.Set(Totals, all, tx.View().GetInt64(Totals, all)+1)
}

func (Impl) Render(v upgrade.View, _ string) string {
	return "# Counter\n\nTotal: " + strconv.FormatInt(v.GetInt64(Totals, all), 10) + "\n"
}
