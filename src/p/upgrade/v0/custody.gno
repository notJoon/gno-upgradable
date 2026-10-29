package upgrade

import (
	"chain"
	"chain/banker"
)

// Custody sends a proxy's coins for an implementation during one crossing
// call. It never hands out the banker it uses, so an implementation keeps
// no access to the coins after the call.
type Custody struct {
	rlm realm
}

// NewCustody returns a Custody over the coins of the realm whose live cur
// is rlm.
func NewCustody(_ int, rlm realm) *Custody {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	return &Custody{rlm: rlm}
}

// Pay sends coins from the proxy to `to`.
func (c *Custody) Pay(to address, coins chain.Coins) {
	if c == nil || c.rlm == nil || !c.rlm.IsCurrent() {
		panic("upgrade: custody is not live")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, c.rlm)
	bnk.SendCoins(c.rlm.Address(), to, coins)
}
