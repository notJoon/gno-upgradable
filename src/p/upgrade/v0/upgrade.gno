package upgrade

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

const (
	ErrInvalidPath  = "upgrade: approved path must be a realm path without a subpath"
	ErrSpoofedRealm = "upgrade: realm must be the proxy's live current realm"
	ErrNotApproved  = "upgrade: caller is not the approved implementation"
	ErrTooEarly     = "upgrade: approval is still in its delay"
	ErrUnauthorized = "upgrade: caller is not the owner"
	ErrFrozen       = "upgrade: upgrades are frozen"
)

// Upgrader records a proxy realm's current implementation and the one
// approved to replace it.
//
// Once an implementation is live, an approval can be accepted only after
// delay blocks, so users can see it coming and leave first. The first
// implementation has no delay because there is nothing to protect yet.
//
// Only the owner may approve, cancel or freeze. The owner is the address
// that called the realm holding the Upgrader: a user, or a realm such as a
// DAO acting at its own address.
//
// The owner check lives here, not in the holding realm. It used to be the
// realm's job: Approve took no realm, and every realm's forwarding function
// had to check its own admin first. A realm that forgot that one line let
// anyone schedule any upgrade. The delay does not save users from that,
// because it only helps if someone notices the approval in time. With the
// check here, the forwarding functions are one line each and cannot leave it
// out, the same way Accept already checked its own caller.
//
// The owner is an address rather than a realm path because one comparison
// then covers both a user and a governance realm, and it avoids the trap of
// matching a path against a user call, whose path is empty.
type Upgrader struct {
	owner    address
	delay    int64
	pkgPath  string
	approved string
	eta      int64 // first height at which approved may be accepted
	frozen   bool
}

// New returns an Upgrader owned by owner whose approvals wait delay blocks.
func New(owner address, delay int64) *Upgrader {
	if !owner.IsValid() {
		panic("upgrade: invalid owner")
	}
	if delay < 0 {
		panic("upgrade: negative delay")
	}
	return &Upgrader{owner: owner, delay: delay}
}

// Approve lets the realm at pkgPath become the next implementation,
// replacing any pending approval. rlm is the holding realm's live cur, and
// its caller must be the owner.
func (u *Upgrader) Approve(_ int, rlm realm, pkgPath string) {
	u.assertOwner(0, rlm)
	u.approve(pkgPath)
}

// approve is Approve without the owner check, for the first approval made
// from the holding realm's init. The owner cannot be checked there, since the
// caller of init is whoever deploys the realm. It needs no check either: no
// implementation is live yet, so there is nothing to protect, and the path
// is written in the realm's source for anyone to read. It is unexported, so a
// realm cannot use it to skip the check later.
func (u *Upgrader) approve(pkgPath string) {
	if u.frozen {
		panic(ErrFrozen)
	}
	// pkgPath must look like `<domain>/r/<path>` and must not name a subrealm.
	// Splitting into at most three parts keeps the rest of the whole path together.
	//
	// 	Example: "example.com/r/myrealm"
	//  After splitting: ["example.com", "r", "myrealm"]
	//
	// This check only catches typos in the approval. The real gate is in Accept,
	// which compares the approval with the calling realm's pkgpath,
	// and no deployed realm can match a malformed path.
	parts := strings.SplitN(pkgPath, "/", 3)
	_, _, isSub := chain.SplitPkgSubPath(pkgPath)
	if len(parts) != 3 || parts[0] == "" || parts[1] != "r" || parts[2] == "" || isSub {
		panic(ErrInvalidPath)
	}
	u.approved = pkgPath
	u.eta = runtime.ChainHeight()
	if u.pkgPath != "" {
		u.eta += u.delay
	}
	chain.Emit("UpgradeApproved", "pkgPath", pkgPath, "eta", strconv.FormatInt(u.eta, 10))
}

// Cancel drops the pending approval, if any. Owner only.
func (u *Upgrader) Cancel(_ int, rlm realm) {
	u.assertOwner(0, rlm)
	if u.approved == "" {
		return
	}
	chain.Emit("UpgradeCancelled", "pkgPath", u.approved)
	u.approved, u.eta = "", 0
}

// Freeze ends upgrades for good, dropping any pending approval. The current
// implementation keeps serving and nothing can replace it, so users can
// trust its code rather than its owner. There is no way back. Owner only.
//
// There is no Unfreeze on purpose: a freeze that can be undone gives users
// nothing they can rely on. Freeze is also the only way to give up the power
// to upgrade. Renouncing the owner instead would also disable the admin
// methods that implementations gate on Owner, such as collecting fees.
func (u *Upgrader) Freeze(_ int, rlm realm) {
	u.assertOwner(0, rlm)
	// Freezing before any implementation is live would leave the realm
	// unable to answer any call, forever.
	if u.pkgPath == "" {
		panic("upgrade: nothing to freeze before the first implementation")
	}
	// Clearing the approval is what stops a pending upgrade from landing
	// after the freeze. Accept needs no frozen check of its own, because it
	// refuses when nothing is approved and approve refuses once frozen.
	u.approved, u.eta, u.frozen = "", 0, true
	chain.Emit("UpgradeFrozen", "pkgPath", u.pkgPath)
}

// TransferOwnership hands the owner role to next. It still works after
// Freeze, because implementations may gate their own admin methods on
// Owner. Owner only.
//
// It takes effect at once, with no delay. It does not need one: whatever
// the new owner approves still waits the delay before it can be accepted.
func (u *Upgrader) TransferOwnership(_ int, rlm realm, next address) {
	u.assertOwner(0, rlm)
	if !next.IsValid() {
		panic("upgrade: invalid owner")
	}
	chain.Emit("OwnershipTransferred", "from", u.owner.String(), "to", next.String())
	u.owner = next
}

// assertOwner panics unless rlm is the holding realm's live cur and its
// caller is the owner. IsCurrent comes first because a realm value whose
// frame has returned still reports that frame's Previous, so a value handed
// out during the owner's call could otherwise pass for the owner later.
func (u *Upgrader) assertOwner(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	if rlm.Previous().Address() != u.owner {
		panic(ErrUnauthorized)
	}
}

func (u *Upgrader) Accept(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}

	caller := rlm.Previous().PkgPath()
	// A user caller has empty package path,
	// so an empty approval must not match.
	if u.approved == "" || caller != u.approved {
		panic(ErrNotApproved)
	}
	if runtime.ChainHeight() < u.eta {
		panic(ErrTooEarly)
	}
	chain.Emit("Upgraded", "from", u.pkgPath, "to", caller)
	u.pkgPath, u.approved, u.eta = caller, "", 0
}

// PkgPath returns the package path of the current implementation,
// or empty string before the first implementation is accepted.
//
// It names the realm that registered, which is not necessarily the realm
// that declares the registered value's type. Audit both.
func (u *Upgrader) PkgPath() string { return u.pkgPath }

// Approved returns the pending approval, or empty string
// if there is no pending approval.
func (u *Upgrader) Approved() string { return u.approved }

// Owner returns the address that may approve, cancel and freeze.
func (u *Upgrader) Owner() address { return u.owner }

// Frozen reports whether Freeze has ended upgrades.
func (u *Upgrader) Frozen() bool { return u.frozen }

// ETA returns the first block height at which the pending approval can be
// accepted, or 0 if there is none.
func (u *Upgrader) ETA() int64 { return u.eta }
