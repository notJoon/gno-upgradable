package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ownable/v0"
	"gno.land/p/upgrade/v0"
)

// Impl is what an implementation realm provides.
// store is the vault's state and rlm is the vault's live cur:
// through rlm an implementation sees the user as `rlm.Previous()`
// and send coins from the vault's address. Both are valid
// only for the duration of the call.
type Impl interface {
	Deposit(tx *upgrade.Tx, amount int64)
	Withdraw(tx *upgrade.Tx, c *Custody, amount int64)
	BalanceOf(v upgrade.View, addr address) int64
	Render(v upgrade.View, path string) string
}

var (
	admin = ownable.NewWithAddress("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	u = upgrade.New()
	store *upgrade.Store
	impl Impl
)

func init(cur realm) {
	store = upgrade.NewStore(0, cur)
	u.Approve("gno.land/r/upgrade/vault/v1")
}

func Approve(cur realm, pkgPath string) {
	admin.AssertOwnedBy(cur.Previous().Address())
	u.Approve(pkgPath)
}

func TransferAdmin(cur realm, newAdmin address) {
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err)
	}
}

// Register is called by the approved implementation realm to take over.
func Register(cur realm, next Impl) {
	if next == nil {
		panic("vault: nil implementation")
	}
	u.Accept(0, cur)
	impl = next
}

func Deposit(cur realm) {
	// OriginSend describes coins that reached the vault only
	// when the user called the vault directly.
	if !cur.Previous().IsUserCall() {
		panic("vault: deposit must be a direct user call")
	}

	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("vault: send ugnot to deposit")
	}
	current().Deposit(store.Begin(0, cur), amount)
}

func Withdraw(cur realm, amount int64) {
	if amount <= 0 {
		panic("vault: withdraw amount must be positive")
	}
	current().Withdraw(store.Begin(0, cur), &Custody{rlm: cur}, amount)
}

func BalanceOf(addr address) int64 {
	return current().BalanceOf(store.View(), addr)
}

func ImplPath() string { return u.PkgPath() }

// Approved returns the implementation path waiting to register,
// if any.
func Approved() string { return u.Approved() }

func Render(path string) string {
	return current().Render(store.View(), path)
}

// --------------------------------------------------

// Custody sends the vault's coin for an implementation.
// It never hands out the banker it uses, so an implementation
// keeps no access to the vault's coins after the call.
//
// Only the vault can build a `Custody` that works: a zero value
// declared elsewhere has no realm and refuses every send.
type Custody struct {
	rlm realm
}

// Pay sends `amount` ugnot from the vault to `to`.
func (c *Custody) Pay(to address, amount int64)  {
	if c == nil || c.rlm == nil || !c.rlm.IsCurrent() {
		panic("vault: custody is not live")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, c.rlm)
	bnk.SendCoins(c.rlm.Address(), to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func current() Impl {
	if impl == nil {
		panic("vault: no implementation registered")
	}
	return impl
}