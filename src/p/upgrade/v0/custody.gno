package upgrade

import (
	"chain"
	"chain/banker"

	"gno.land/p/nt/grc20/v0"
)

// Custody moves a proxy's coins and GRC20 tokens for an implementation
// during one crossing call.
//
// It never hands out a banker or a teller. A grc20 RealmTeller stays bound
// to the proxy's address for good and checks only that whoever calls it
// holds some live cur, so an implementation that kept one could spend the
// proxy's tokens after being replaced. Custody builds one per call and
// drops it.
type Custody struct {
	rlm       realm
	approvals []approval
}

type approval struct {
	tok     *grc20.Token
	spender address
}

// NewCustody returns a Custody over the assets of the realm whose live cur
// is rlm.
func NewCustody(_ int, rlm realm) *Custody {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	return &Custody{rlm: rlm}
}

// Address returns the proxy's address, which holds the assets.
func (c *Custody) Address() address {
	c.assertLive()
	return c.rlm.Address()
}

// Pay sends coins from the proxy to `to`.
func (c *Custody) Pay(to address, coins chain.Coins) {
	c.assertLive()
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, c.rlm)
	bnk.SendCoins(c.rlm.Address(), to, coins)
}

// Transfer sends amount of tok from the proxy to `to`.
func (c *Custody) Transfer(tok *grc20.Token, to address, amount int64) {
	c.assertLive()
	must(tok.RealmTeller(0, c.rlm).Transfer(0, c.rlm, to, amount))
}

// TransferFrom moves amount of tok from owner to `to`, spending the
// allowance owner gave the proxy. This is how a proxy takes tokens from a
// user or realm that approved it.
func (c *Custody) TransferFrom(tok *grc20.Token, owner, to address, amount int64) {
	c.assertLive()
	must(tok.RealmTeller(0, c.rlm).TransferFrom(0, c.rlm, owner, to, amount))
}

// ApproveForCall lets spender take up to amount of tok until the current proxy
// call returns. The proxy clears the allowance before the call can commit.
func (c *Custody) ApproveForCall(tok *grc20.Token, spender address, amount int64) {
	c.assertLive()
	must(tok.RealmTeller(0, c.rlm).Approve(0, c.rlm, spender, amount))
	c.approvals = append(c.approvals, approval{tok: tok, spender: spender})
}

func (c *Custody) close() {
	c.assertLive()
	for _, a := range c.approvals {
		must(a.tok.RealmTeller(0, c.rlm).Approve(0, c.rlm, a.spender, 0))
	}
	c.approvals = nil
}

func (c *Custody) assertLive() {
	if c == nil || c.rlm == nil || !c.rlm.IsCurrent() {
		panic("upgrade: custody is not live")
	}
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}
