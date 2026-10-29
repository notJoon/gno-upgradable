package vault

import (
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/upgrade/v0"
)

// Impl is what an implementation realm provides.
// store is the vault's state and rlm is the vault's live cur:
// through rlm an implementation sees the user as `rlm.Previous()`
// and send coins from the vault's address. Both are valid
// only for the duration of the call.
type Impl interface {
	Deposit(store *avl.Tree, rlm realm, amount int64)
	Withdraw(store *avl.Tree, rlm realm, amount int64)
	BalanceOf(store *avl.Tree, addr address) int64
	Render(store *avl.Tree, path string) string
}

var (
	admin = ownable.NewWithAddress("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	store = avl.NewTree()
	u = upgrade.New()
	impl Impl
)

func init() {
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
	current().Deposit(store, cur, amount)
}

func Withdraw(cur realm, amount int64) {
	if amount <= 0 {
		panic("vault: withdraw amount must be positive")
	}
	current().Withdraw(store, cur, amount)
}

func BalanceOf(addr address) int64 {
	return current().BalanceOf(store, addr)
}

func ImplPath() string { return u.PkgPath() }

// Approved returns the implementation path waiting to register,
// if any.
func Approved() string { return u.Approved() }

func Render(path string) string {
	return current().Render(store, path)
}

func current() Impl {
	if impl == nil {
		panic("vault: no implementation registered")
	}
	return impl
}